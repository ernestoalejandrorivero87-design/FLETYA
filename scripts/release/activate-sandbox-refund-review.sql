-- FLETYA Pruebas only. Apply after the sandbox card refund migration.
alter table private.stripe_sandbox_orders
  drop constraint stripe_sandbox_orders_refund_state_check,
  add constraint stripe_sandbox_orders_refund_state_check
    check(refund_state in ('requested','confirmed','review','denied'));
alter table public.jobs
  drop constraint jobs_sandbox_refund_state_check,
  add constraint jobs_sandbox_refund_state_check
    check(sandbox_refund_state in ('requested','confirmed','review','denied'));

create table private.stripe_sandbox_refund_decisions (
  order_id uuid primary key references private.stripe_sandbox_orders(id) on delete cascade,
  reviewer_id uuid references auth.users(id) on delete set null,
  approved boolean not null,
  note text not null check(char_length(note) between 10 and 500),
  decided_at timestamptz not null default now()
);
alter table private.stripe_sandbox_refund_decisions enable row level security;
revoke all on private.stripe_sandbox_refund_decisions from public,anon,authenticated,service_role;

create function private.review_sandbox_refund(
  p_id uuid, p_approved boolean, p_note text
) returns jsonb language plpgsql security definer set search_path='' as $$
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
end $$;
create function public.review_sandbox_refund(p_id uuid default null,p_approved boolean default null,p_note text default null)
returns jsonb language sql security invoker set search_path='' as $$
  select private.review_sandbox_refund(p_id,p_approved,p_note);
$$;
revoke all on function private.review_sandbox_refund(uuid,boolean,text),public.review_sandbox_refund(uuid,boolean,text)
  from public,anon,authenticated;
grant execute on function private.review_sandbox_refund(uuid,boolean,text),public.review_sandbox_refund(uuid,boolean,text)
  to authenticated;

create or replace function public.stripe_sandbox_refund(
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
    if p_status='confirmed' and exists(
      select 1 from private.stripe_sandbox_refund_decisions where order_id=p_id and approved
    ) then
      insert into public.notifications(user_id,job_id,title,message,type)
        values(job.client_id,p_id,'Reembolso confirmado',
          'Stripe confirmó la devolución completa del pago de prueba.','client_refund_confirmed');
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
end $$;
notify pgrst,'reload schema';
