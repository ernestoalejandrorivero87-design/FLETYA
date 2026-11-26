-- PRUEBAS only. Requires existing cash commission and driver push functions.
BEGIN;
CREATE OR REPLACE FUNCTION public.claim_driver_push_batch(p_secret text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare output jsonb;
begin
 if not exists(select 1 from private.driver_push_config where enabled
   and secret_hash=encode(sha256(convert_to(coalesce(p_secret,''),'UTF8')),'hex')) then
  raise insufficient_privilege using message='Invalid push authorization';
 end if;
 delete from private.driver_push_outbox where created_at<now()-interval '7 days';
 with candidates as (
  select notification_id from private.driver_push_outbox
  where completed_at is null and attempts<5 and available_at<=now()
   and (locked_until is null or locked_until<now())
  order by available_at,notification_id for update skip locked limit 10
 ), claimed as (
  update private.driver_push_outbox o set attempts=o.attempts+1,locked_until=now()+interval '90 seconds'
  from candidates c where o.notification_id=c.notification_id returning o.*
 )
 select coalesce(jsonb_agg(jsonb_build_object(
  'notification_id',c.notification_id,'user_id',c.user_id,'job_id',c.job_id,'event_type',(select n.type from public.notifications n where n.id=c.notification_id),'attempt',c.attempts,'message',(select n.message from public.notifications n where n.id=c.notification_id and n.type='cash_commission_settled'),
  'devices',coalesce((select jsonb_agg(jsonb_build_object('installation_id',d.installation_id,'token',d.token,'registration_nonce',d.registration_nonce))
   from public.driver_push_devices d join public.profiles p on p.id=d.user_id and p.role='driver'
   where d.user_id=c.user_id and d.enabled
   and private.driver_push_session_active(d.session_id,d.user_id)
   and c.created_at>now()-interval '5 minutes'
   and (
     (exists(select 1 from public.notifications n where n.id=c.notification_id and n.type in ('cash_issue_payment_required','cash_issue_paid','cash_commission_settled'))
       and exists(select 1 from public.jobs j where j.id=c.job_id and j.driver_id=c.user_id))
     or
     (exists(select 1 from public.notifications n where n.id=c.notification_id and n.type not in ('cash_issue_payment_required','cash_issue_paid','cash_commission_settled'))
       and exists(select 1 from public.jobs j where j.id=c.job_id and j.status='requested' and j.driver_id is null)
       and not exists(select 1 from public.jobs active where active.driver_id=c.user_id and active.status in ('en_route','picked_up')))
   )),'[]'::jsonb)
 )),'[]'::jsonb) into output from claimed c;
 return output;
end $function$
;

CREATE OR REPLACE FUNCTION private.queue_driver_push()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if new.job_id is not null
 and exists(select 1 from public.profiles p where p.id=new.user_id and p.role='driver')
 and (
   (new.type in ('cash_issue_payment_required','cash_issue_paid','cash_commission_settled')
     and exists(select 1 from public.jobs j where j.id=new.job_id and j.driver_id=new.user_id))
   or
   (new.type not in ('cash_issue_payment_required','cash_issue_paid','cash_commission_settled')
     and exists(select 1 from public.jobs j where j.id=new.job_id and j.status='requested' and j.driver_id is null))
 )
 then
  insert into private.driver_push_outbox(notification_id,user_id,job_id) values(new.id,new.user_id,new.job_id) on conflict do nothing;
  perform private.wake_driver_push();
 end if;
 return new;
end $function$
;

CREATE OR REPLACE FUNCTION private.settle_cash_commission_cut(p_driver uuid, p_week date, p_expected_cents bigint, p_expected_count integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  job_ids uuid[];
  actual_cents bigint;
  changed integer;
begin
  if not private.is_admin() then raise insufficient_privilege; end if;
  if p_driver is null or p_week is null or extract(isodow from p_week) <> 1
     or p_week + 7 > (now() at time zone 'America/Cancun')::date
     or p_expected_cents is null or p_expected_cents < 0 or p_expected_count is null or p_expected_count < 1 then
    raise invalid_parameter_value using message = 'Selecciona un corte cerrado y pendiente.';
  end if;
  select array_agg(item.id), sum(round(item.price * 15)) into job_ids, actual_cents
  from (
    select id, price from public.jobs where driver_id=p_driver and status='completed'
      and payment_method='cash' and cash_commission_settled_at is null
      and cash_collected_at >= p_week::timestamp at time zone 'America/Cancun'
      and cash_collected_at < (p_week + 7)::timestamp at time zone 'America/Cancun'
    order by id for update
  ) item;
  if cardinality(job_ids) is distinct from p_expected_count or actual_cents is distinct from p_expected_cents then
    raise invalid_parameter_value using message = 'El corte cambió. Actualiza y comprueba el importe antes de registrarlo.';
  end if;
  update public.jobs set cash_commission_settled_at = now() where id = any(job_ids);
  get diagnostics changed = row_count;
  insert into public.notifications(user_id,title,message,type,job_id,read)
  values(p_driver,'Comisiones liquidadas',format('Corte del %s al %s: $%s MXN liquidados. Saldo pendiente de este corte: $0.00.',p_week,p_week+6,to_char(actual_cents::numeric/100,'FM999999990.00')),'cash_commission_settled',job_ids[1],false);
  return changed;
end $function$
;
COMMIT;
