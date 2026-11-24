-- FLETYA / PRUEBAS ONLY (project ccdtpwvalqznasstnqxj)
-- Records the cash issue push and admin recovery changes deployed on 2026-11-24.
-- Do NOT apply against the PILOTO Supabase project.
-- Run in PRUEBAS only after the underlying cash issue module and push outboxes exist.

create or replace function private.queue_client_push()
returns trigger language plpgsql security definer set search_path to ''
as $fn$
begin
 if new.type in ('client_requested','client_assigned','client_arrived_pickup','client_picked_up',
                 'client_arrived_delivery','client_completed','client_cancelled','client_released',
                 'cash_issue_payment_required','cash_issue_paid')
 and new.job_id is not null
 and exists(select 1 from public.jobs j join public.profiles p on p.id=j.client_id and p.role='client'
            where j.id=new.job_id and j.client_id=new.user_id)
 then
   insert into private.client_push_outbox(notification_id,user_id,job_id,event_type)
   values(new.id,new.user_id,new.job_id,new.type) on conflict do nothing;
   perform private.wake_client_push();
 end if;
 return new;
end $fn$;
revoke all on function private.queue_client_push() from public,anon,authenticated;

create or replace function private.queue_driver_push()
returns trigger language plpgsql security definer set search_path to ''
as $fn$
begin
 if new.job_id is not null
 and exists(select 1 from public.profiles p where p.id=new.user_id and p.role='driver')
 and (
  (new.type in ('cash_issue_payment_required','cash_issue_paid')
    and exists(select 1 from public.jobs j where j.id=new.job_id and j.driver_id=new.user_id))
  or
  (new.type not in ('cash_issue_payment_required','cash_issue_paid')
    and exists(select 1 from public.jobs j where j.id=new.job_id and j.status='requested' and j.driver_id is null))
 ) then
   insert into private.driver_push_outbox(notification_id,user_id,job_id)
   values(new.id,new.user_id,new.job_id) on conflict do nothing;
   perform private.wake_driver_push();
 end if;
 return new;
end $fn$;
revoke all on function private.queue_driver_push() from public,anon,authenticated;

do $migration$
declare original text; updated text;
begin
 select pg_get_functiondef('public.claim_client_push_batch(text)'::regprocedure) into original;
 updated := replace(original,
 $old$and not exists(select 1 from private.client_push_outbox newer where newer.user_id=c.user_id and newer.job_id=c.job_id and newer.sequence_id>c.sequence_id)$old$,
 $new$and (c.event_type in ('cash_issue_payment_required','cash_issue_paid') or not exists(select 1 from private.client_push_outbox newer where newer.user_id=c.user_id and newer.job_id=c.job_id and newer.sequence_id>c.sequence_id))$new$);
 if updated <> original then execute updated;
 elsif position('c.event_type in' in original)=0 then raise exception 'Unexpected client claim baseline'; end if;

 select pg_get_functiondef('public.claim_driver_push_batch(text)'::regprocedure) into original;
 updated:=replace(original,
 $old$'notification_id',c.notification_id,'user_id',c.user_id,'job_id',c.job_id,'attempt',c.attempts,$old$,
 $new$'notification_id',c.notification_id,'user_id',c.user_id,'job_id',c.job_id,'event_type',(select n.type from public.notifications n where n.id=c.notification_id),'attempt',c.attempts,$new$);
 if updated <> original then original:=updated;
 elsif position('event_type' in original)=0 then raise exception 'Unexpected driver claim baseline'; end if;
 updated:=replace(original,
 $old$and exists(select 1 from public.jobs j where j.id=c.job_id and j.status='requested' and j.driver_id is null)
   and not exists(select 1 from public.jobs active where active.driver_id=c.user_id and active.status in ('en_route','picked_up'))$old$,
 $new$and (
     (exists(select 1 from public.notifications n where n.id=c.notification_id and n.type in ('cash_issue_payment_required','cash_issue_paid'))
       and exists(select 1 from public.jobs j where j.id=c.job_id and j.driver_id=c.user_id))
     or
     (exists(select 1 from public.notifications n where n.id=c.notification_id and n.type not in ('cash_issue_payment_required','cash_issue_paid'))
       and exists(select 1 from public.jobs j where j.id=c.job_id and j.status='requested' and j.driver_id is null)
       and not exists(select 1 from public.jobs active where active.driver_id=c.user_id and active.status in ('en_route','picked_up')))
   )$new$);
 if updated <> original then execute updated;
 elsif position('cash_issue_paid' in original)=0 then raise exception 'Unexpected driver eligibility baseline'; end if;
end $migration$;

-- The private handler checks private.is_admin() and enforces completed cash jobs.
-- Expose its existing public RPC only to authenticated users, never anonymous.
grant execute on function private.record_cash_payment(uuid,text) to authenticated;
grant execute on function public.record_cash_payment(uuid,text) to authenticated;
revoke all on function private.record_cash_payment(uuid,text) from anon;
revoke all on function public.record_cash_payment(uuid,text) from anon;
