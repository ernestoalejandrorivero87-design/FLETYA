-- FLETYA Pruebas only. Apply after the sandbox card authorization migration.
alter table private.stripe_sandbox_orders
  add column refund_id text unique,
  add column refund_state text check (refund_state in ('requested','confirmed','review'));

alter table public.jobs add column sandbox_refund_state text
  check (sandbox_refund_state in ('requested','confirmed','review'));

create function private.guard_sandbox_refund_job() returns trigger
language plpgsql set search_path='' as $$
begin
  if current_user in ('postgres','service_role') then return new; end if;
  if tg_op='INSERT' then
    if new.sandbox_refund_state is not null then raise insufficient_privilege; end if;
  elsif new.sandbox_refund_state is distinct from old.sandbox_refund_state
     or (old.sandbox_card_state='paid' and new.status='cancelled') then
    raise insufficient_privilege using message='Usa la cancelación con reembolso de FLETYA.';
  end if;
  return new;
end $$;
create trigger guard_sandbox_refund_job before insert or update on public.jobs
for each row execute function private.guard_sandbox_refund_job();

create function public.stripe_sandbox_refund(
  p_action text, p_id uuid, p_actor uuid default null,
  p_refund text default null, p_status text default null
) returns jsonb language plpgsql security definer set search_path='' as $$
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
    end if;
  elsif p_action='record' then
    if attempt.refund_state is distinct from 'requested' or job.status <> 'cancelled' then
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
end $$;
revoke all on function public.stripe_sandbox_refund(text,uuid,uuid,text,text) from public,anon,authenticated,service_role;
grant execute on function public.stripe_sandbox_refund(text,uuid,uuid,text,text) to service_role;

create or replace function public.stripe_sandbox_due(p_token uuid) returns jsonb
language sql security definer set search_path='' as $$
  select coalesce(jsonb_agg(d.id),'[]'::jsonb) from (
    select id from private.stripe_sandbox_orders
    where exists(select 1 from private.stripe_sandbox_scheduler where token=p_token)
      and (refund_state='requested' or card_state in ('capturing','releasing')
        or (card_state='held' and hold_until <= now()))
    order by hold_until nulls first limit 20
  ) d;
$$;
notify pgrst,'reload schema';
