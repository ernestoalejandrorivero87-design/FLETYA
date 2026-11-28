-- PRUEBAS only. Review dependencies and grants before any Pilot migration.
begin;
create table if not exists private.sandbox_card_refund_resolutions_v1(job_id uuid primary key references private.sandbox_card_driver_settlements_v1(job_id),platform_cents bigint not null check(platform_cents>=0),driver_cents bigint not null check(driver_cents>=0),note text not null check(char_length(btrim(note)) between 10 and 500),recorded_by uuid not null,recorded_at timestamptz not null default now());
create table if not exists private.sandbox_card_refund_recoveries_v1(job_id uuid primary key references private.sandbox_card_refund_resolutions_v1(job_id),amount_cents bigint not null check(amount_cents>0),note text not null check(char_length(btrim(note)) between 10 and 500),recorded_by uuid not null,recorded_at timestamptz not null default now());
alter table private.sandbox_card_refund_resolutions_v1 enable row level security;
alter table private.sandbox_card_refund_recoveries_v1 enable row level security;
revoke all on private.sandbox_card_refund_resolutions_v1,private.sandbox_card_refund_recoveries_v1 from public,anon,authenticated;
CREATE OR REPLACE FUNCTION private.queue_client_push()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if new.type in ('client_requested','client_assigned','client_arrived_pickup','client_picked_up','client_arrived_delivery','client_completed','client_cancelled','client_released','cash_issue_payment_required','cash_issue_paid','client_refund_requested','client_refund_approved','client_refund_denied','client_refund_confirmed')
 and new.job_id is not null
 and exists(select 1 from public.jobs j join public.profiles p on p.id=j.client_id and p.role='client' where j.id=new.job_id and j.client_id=new.user_id)
 then
  insert into private.client_push_outbox(notification_id,user_id,job_id,event_type)
  values(new.id,new.user_id,new.job_id,new.type) on conflict do nothing;
  perform private.wake_client_push();
 end if;
 return new;
end
$function$
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
   (new.type in ('cash_issue_payment_required','cash_issue_paid','cash_commission_settled','sandbox_refund_adjustment_resolved','sandbox_refund_recovery_confirmed')
     and exists(select 1 from public.jobs j where j.id=new.job_id and j.driver_id=new.user_id))
   or
   (new.type not in ('cash_issue_payment_required','cash_issue_paid','cash_commission_settled','sandbox_refund_adjustment_resolved','sandbox_refund_recovery_confirmed')
     and exists(select 1 from public.jobs j where j.id=new.job_id and j.status='requested' and j.driver_id is null))
 )
 then
  insert into private.driver_push_outbox(notification_id,user_id,job_id) values(new.id,new.user_id,new.job_id) on conflict do nothing;
  perform private.wake_driver_push();
 end if;
 return new;
end $function$
;

CREATE OR REPLACE FUNCTION private.record_sandbox_refund_recovery_v1(p_job uuid, p_expected_cents bigint, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$ declare a private.sandbox_card_refund_resolutions_v1%rowtype; r private.sandbox_card_refund_recoveries_v1%rowtype; begin if auth.uid() is null or not private.is_admin() then raise insufficient_privilege; end if; select * into a from private.sandbox_card_refund_resolutions_v1 where job_id=p_job for update; if not found or a.driver_cents<=0 or p_expected_cents is distinct from a.driver_cents or p_note is null or char_length(btrim(p_note)) not between 10 and 500 then raise invalid_parameter_value; end if; insert into private.sandbox_card_refund_recoveries_v1(job_id,amount_cents,note,recorded_by) values(p_job,a.driver_cents,btrim(p_note),auth.uid()) returning * into r; insert into public.notifications(user_id,title,message,type,job_id,read) select driver_id,'Reintegro confirmado',format('PRUEBAS: servicio %s. Reintegro simulado recibido MXN %s. Pendiente de este ajuste: MXN 0.00.',upper(left(p_job::text,8)),to_char(r.amount_cents::numeric/100,'FM999999990.00')),'sandbox_refund_recovery_confirmed',id,false from public.jobs where id=p_job and driver_id is not null; return to_jsonb(r); end $function$
;

CREATE OR REPLACE FUNCTION private.resolve_sandbox_card_refund_v1(p_job uuid, p_driver_cents bigint, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s private.sandbox_card_driver_settlements_v1%rowtype; r private.sandbox_card_refund_resolutions_v1%rowtype;
begin
if auth.uid() is null or not private.is_admin() then raise insufficient_privilege; end if;
perform 1 from private.stripe_sandbox_orders where id=p_job and method='card' and card_state='paid' and refund_state='confirmed' for update;
if not found then raise invalid_parameter_value; end if;
select * into s from private.sandbox_card_driver_settlements_v1 where job_id=p_job for update;
if not found or p_driver_cents is null or p_driver_cents<0 or p_driver_cents>s.amount_cents or p_note is null or char_length(btrim(p_note)) not between 10 and 500 then raise invalid_parameter_value; end if;
insert into private.sandbox_card_refund_resolutions_v1(job_id,platform_cents,driver_cents,note,recorded_by) values(p_job,s.amount_cents-p_driver_cents,p_driver_cents,btrim(p_note),auth.uid()) returning * into r;
insert into public.notifications(user_id,title,message,type,job_id,read) select driver_id,'Ajuste financiero resuelto',format('PRUEBAS: servicio %s. FLETYA asume MXN %s. Reintegro acordado MXN %s.',upper(left(p_job::text,8)),to_char(r.platform_cents::numeric/100,'FM999999990.00'),to_char(r.driver_cents::numeric/100,'FM999999990.00')),'sandbox_refund_adjustment_resolved',id,false from public.jobs where id=p_job and driver_id is not null; return to_jsonb(r);
end $function$
;

CREATE OR REPLACE FUNCTION private.review_sandbox_refund(p_id uuid, p_approved boolean, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  attempt private.stripe_sandbox_orders;
  job public.jobs;
  next_refund_state text;
  note text := btrim(p_note);
begin
  if actor is null or not private.is_admin() then raise insufficient_privilege; end if;
  if p_id is null then
    return coalesce((
      select jsonb_agg(to_jsonb(cases)) from (
        select j.id, j.status, j.service_type, j.created_at, o.amount, o.refund_state,
          p.full_name as client_name, d.approved, d.note, d.decided_at
        from private.stripe_sandbox_orders o
        join public.jobs j on j.id=o.id
        left join public.profiles p on p.id=j.client_id
        left join private.stripe_sandbox_refund_decisions d on d.order_id=o.id
        where o.method='card' and o.card_state='paid'
          and ((o.refund_state='review' and j.status in ('picked_up','completed')) or d.order_id is not null)
        order by (d.order_id is null) desc, j.created_at desc, j.id
        limit 50
      ) cases
    ),'[]'::jsonb);
  end if;
  if p_approved is null or note is null or char_length(note) not between 10 and 500 then
    raise invalid_parameter_value;
  end if;

  select * into attempt from private.stripe_sandbox_orders where id=p_id and method='card';
  if not found then return null; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('fletya-route-order:' || attempt.client_id::text,0));
  select * into attempt from private.stripe_sandbox_orders where id=p_id;
  select * into job from public.jobs where id=p_id for update;
  if job.id is null or job.status not in ('picked_up','completed')
     or attempt.card_state is distinct from 'paid' or attempt.refund_state is distinct from 'review'
     or attempt.card_intent is null or attempt.refund_id is not null then return null; end if;

  insert into private.stripe_sandbox_refund_decisions(order_id,reviewer_id,approved,note)
    values(p_id,actor,p_approved,note) on conflict(order_id) do nothing;
  if not found then return null; end if;
  next_refund_state := case when p_approved then 'requested' else 'denied' end;
  update private.stripe_sandbox_orders set refund_state=next_refund_state where id=p_id;
  update public.jobs set sandbox_refund_state=next_refund_state where id=p_id;
  insert into public.notifications(user_id,job_id,title,message,type)
    values(job.client_id,p_id,
      case when p_approved then 'Reembolso aprobado' else 'Reembolso rechazado' end,
      note, case when p_approved then 'client_refund_approved' else 'client_refund_denied' end);
  return jsonb_build_object('id',p_id,'refund_state',next_refund_state);
end $function$
;

CREATE OR REPLACE FUNCTION private.sandbox_card_financial_summary_v1()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$ begin if not private.is_admin() then raise insufficient_privilege; end if; return (select jsonb_build_object('captured_cents',coalesce(sum(round(a.amount*100)) filter(where a.card_state='paid'),0),'refunded_cents',coalesce(sum(round(a.amount*100)) filter(where a.card_state='paid' and a.refund_state='confirmed'),0),'settled_cents',coalesce(sum(s.amount_cents),0),'settled_refund_review_cents',coalesce(sum(s.amount_cents) filter(where a.refund_state='confirmed' and r.job_id is null),0),'settled_refund_review_count',count(*) filter(where a.refund_state='confirmed' and s.job_id is not null and r.job_id is null),'platform_assumed_cents',coalesce(sum(r.platform_cents),0),'recovered_cents',coalesce(sum(k.amount_cents),0),'driver_agreed_cents',coalesce(sum(r.driver_cents),0)) from private.stripe_sandbox_orders a left join private.sandbox_card_driver_settlements_v1 s on s.job_id=a.id left join private.sandbox_card_refund_resolutions_v1 r on r.job_id=s.job_id left join private.sandbox_card_refund_recoveries_v1 k on k.job_id=r.job_id where a.method='card'); end $function$
;

CREATE OR REPLACE FUNCTION private.sandbox_card_settlement_status_v1()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$ begin if not private.is_admin() then raise insufficient_privilege; end if; return coalesce((select jsonb_agg(jsonb_build_object('job_id',a.id,'eligible',a.card_state='paid' and (a.refund_state is null or a.refund_state='denied') and j.status='completed' and j.sandbox_card_state='paid' and j.driver_id is not null and j.test_driver_payout between 0 and a.amount,'settled_cents',s.amount_cents,'refund_state',a.refund_state,'recovery',case when k.job_id is not null then to_jsonb(k) else null end,'resolution',case when r.job_id is not null then to_jsonb(r) else null end)) from private.stripe_sandbox_orders a join public.jobs j on j.id=a.id left join private.sandbox_card_driver_settlements_v1 s on s.job_id=a.id left join private.sandbox_card_refund_resolutions_v1 r on r.job_id=a.id left join private.sandbox_card_refund_recoveries_v1 k on k.job_id=r.job_id where a.method='card'),'[]'::jsonb); end $function$
;

CREATE OR REPLACE FUNCTION public.claim_client_push_batch(p_secret text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare output jsonb;
begin
 if not public.authorize_push_hook(p_secret) then raise insufficient_privilege using message='Invalid push authorization';end if;
 delete from private.client_push_outbox where created_at<now()-interval '7 days';
 with candidates as(
  select notification_id from private.client_push_outbox where completed_at is null and attempts<5 and available_at<=now()
   and (locked_until is null or locked_until<now()) order by available_at,sequence_id for update skip locked limit 10
 ),claimed as(
  update private.client_push_outbox o set attempts=o.attempts+1,locked_until=now()+interval '90 seconds'
  from candidates c where o.notification_id=c.notification_id returning o.*
 )
 select coalesce(jsonb_agg(jsonb_build_object('notification_id',c.notification_id,'user_id',c.user_id,'job_id',c.job_id,'event_type',c.event_type,'attempt',c.attempts,'message',(select n.message from public.notifications n where n.id=c.notification_id and n.type like 'client_refund_%'),
  'devices',coalesce((select jsonb_agg(jsonb_build_object('installation_id',d.installation_id,'token',d.token,'registration_nonce',d.registration_nonce))
   from public.client_push_devices d join public.profiles p on p.id=d.user_id and p.role='client'
   where d.user_id=c.user_id and d.enabled and private.driver_push_session_active(d.session_id,d.user_id)
   and c.created_at>now()-interval '10 minutes'
   and exists(select 1 from public.jobs j where j.id=c.job_id and j.client_id=c.user_id)
   and (c.event_type in ('cash_issue_payment_required','cash_issue_paid','client_refund_requested','client_refund_approved','client_refund_denied','client_refund_confirmed') or not exists(select 1 from private.client_push_outbox newer where newer.user_id=c.user_id and newer.job_id=c.job_id and newer.sequence_id>c.sequence_id and newer.event_type not like 'client_refund_%'))), '[]'::jsonb)
 )),'[]'::jsonb) into output from claimed c;return output;
end $function$
;

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
  'notification_id',c.notification_id,'user_id',c.user_id,'job_id',c.job_id,'event_type',(select n.type from public.notifications n where n.id=c.notification_id),'attempt',c.attempts,'message',(select n.message from public.notifications n where n.id=c.notification_id and n.type in ('cash_commission_settled','sandbox_refund_adjustment_resolved','sandbox_refund_recovery_confirmed')),
  'devices',coalesce((select jsonb_agg(jsonb_build_object('installation_id',d.installation_id,'token',d.token,'registration_nonce',d.registration_nonce))
   from public.driver_push_devices d join public.profiles p on p.id=d.user_id and p.role='driver'
   where d.user_id=c.user_id and d.enabled
   and private.driver_push_session_active(d.session_id,d.user_id)
   and c.created_at>now()-interval '5 minutes'
   and (
     (exists(select 1 from public.notifications n where n.id=c.notification_id and n.type in ('cash_issue_payment_required','cash_issue_paid','cash_commission_settled','sandbox_refund_adjustment_resolved','sandbox_refund_recovery_confirmed'))
       and exists(select 1 from public.jobs j where j.id=c.job_id and j.driver_id=c.user_id))
     or
     (exists(select 1 from public.notifications n where n.id=c.notification_id and n.type not in ('cash_issue_payment_required','cash_issue_paid','cash_commission_settled','sandbox_refund_adjustment_resolved','sandbox_refund_recovery_confirmed'))
       and exists(select 1 from public.jobs j where j.id=c.job_id and j.status='requested' and j.driver_id is null)
       and not exists(select 1 from public.jobs active where active.driver_id=c.user_id and active.status in ('en_route','picked_up')))
   )),'[]'::jsonb)
 )),'[]'::jsonb) into output from claimed c;
 return output;
end $function$
;

CREATE OR REPLACE FUNCTION public.record_sandbox_refund_recovery_v1(p_job uuid, p_expected_cents bigint, p_note text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select private.record_sandbox_refund_recovery_v1(p_job,p_expected_cents,p_note) $function$
;

CREATE OR REPLACE FUNCTION public.resolve_sandbox_card_refund_v1(p_job uuid, p_driver_cents bigint, p_note text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select private.resolve_sandbox_card_refund_v1(p_job,p_driver_cents,p_note) $function$
;

CREATE OR REPLACE FUNCTION public.review_sandbox_refund(p_id uuid DEFAULT NULL::uuid, p_approved boolean DEFAULT NULL::boolean, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$
  select private.review_sandbox_refund(p_id,p_approved,p_note);
$function$
;

CREATE OR REPLACE FUNCTION public.sandbox_card_financial_summary_v1()
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select private.sandbox_card_financial_summary_v1() $function$
;

CREATE OR REPLACE FUNCTION public.sandbox_card_settlement_status_v1()
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select private.sandbox_card_settlement_status_v1() $function$
;

CREATE OR REPLACE FUNCTION public.stripe_sandbox_refund(p_action text, p_id uuid, p_actor uuid DEFAULT NULL::uuid, p_refund text DEFAULT NULL::text, p_status text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  attempt private.stripe_sandbox_orders;
  job public.jobs;
begin
  select * into attempt from private.stripe_sandbox_orders where id=p_id and method='card';
  if not found then return null; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('fletya-route-order:' || attempt.client_id::text,0));
  select * into attempt from private.stripe_sandbox_orders where id=p_id;
  select * into job from public.jobs where id=p_id for update;
  if job.id is null or attempt.card_state is distinct from 'paid' or attempt.card_intent is null then
    return null;
  end if;

  if p_action='request' then
    if p_actor is null or attempt.client_id is distinct from p_actor
      or job.client_id is distinct from p_actor then return null; end if;
    if attempt.refund_state is null then
      if job.status in ('en_route','requested') then
        -- A concurrent pickup either wins the row lock or is rejected after cancellation.
        update public.jobs set status='cancelled',sandbox_refund_state='requested'
          where id=p_id returning * into job;
        update private.stripe_sandbox_orders set refund_state='requested'
          where id=p_id returning * into attempt;
      elsif job.status in ('picked_up','completed') then
        update public.jobs set sandbox_refund_state='review' where id=p_id returning * into job;
        update private.stripe_sandbox_orders set refund_state='review'
          where id=p_id returning * into attempt;
        insert into public.notifications(user_id,job_id,title,message,type)
          select id,p_id,'Reembolso de prueba para revisar',
            'El cliente solicitó revisar la devolución después de la recogida.','admin_refund_review'
          from public.profiles where role='admin';
      else
        return null;
      end if;
      insert into public.notifications(user_id,job_id,title,message,type) values(job.client_id,p_id,'Solicitud de reembolso recibida','PRUEBAS: recibimos tu solicitud de devolución. Consulta su estado en FLETYA.','client_refund_requested');
    end if;
  elsif p_action='record' then
    if attempt.refund_state is distinct from 'requested' or
       (job.status <> 'cancelled' and not exists(
         select 1 from private.stripe_sandbox_refund_decisions where order_id=p_id and approved
       )) then
      return jsonb_build_object('job',to_jsonb(job),'order',to_jsonb(attempt));
    end if;
    if p_status is null or p_status not in ('requested','confirmed','review') or
      (p_refund is not null and p_refund !~ '^re_[A-Za-z0-9]+$') or
      (p_status='confirmed' and p_refund is null) or
      (attempt.refund_id is not null and p_refund is distinct from attempt.refund_id) then
      return null;
    end if;
    update private.stripe_sandbox_orders set refund_state=p_status,refund_id=p_refund
      where id=p_id returning * into attempt;
    update public.jobs set sandbox_refund_state=p_status where id=p_id returning * into job;
    if p_status='confirmed' then
      insert into public.notifications(user_id,job_id,title,message,type)
        values(job.client_id,p_id,'Reembolso confirmado',
          format('PRUEBAS: Stripe confirmó la devolución de $%s MXN del pago simulado.',to_char(attempt.amount,'FM999999990.00')),'client_refund_confirmed');
    end if;
    if p_status='review' then
      insert into public.notifications(user_id,job_id,title,message,type)
        select id,p_id,'Reembolso de prueba para revisar',
          'Stripe requiere revisión para completar la devolución.','admin_refund_review'
        from public.profiles where role='admin';
    end if;
  elsif p_action <> 'reconcile' then
    return null;
  end if;
  return jsonb_build_object('job',to_jsonb(job),'order',to_jsonb(attempt));
end $function$
;
revoke all on function private.resolve_sandbox_card_refund_v1(uuid,bigint,text) from public,anon,authenticated;
grant execute on function private.resolve_sandbox_card_refund_v1(uuid,bigint,text) to authenticated;
revoke all on function private.record_sandbox_refund_recovery_v1(uuid,bigint,text) from public,anon,authenticated;
grant execute on function private.record_sandbox_refund_recovery_v1(uuid,bigint,text) to authenticated;
revoke all on function public.resolve_sandbox_card_refund_v1(uuid,bigint,text) from public,anon,authenticated;
grant execute on function public.resolve_sandbox_card_refund_v1(uuid,bigint,text) to authenticated;
revoke all on function public.record_sandbox_refund_recovery_v1(uuid,bigint,text) from public,anon,authenticated;
grant execute on function public.record_sandbox_refund_recovery_v1(uuid,bigint,text) to authenticated;
commit;
