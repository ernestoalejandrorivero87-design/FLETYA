-- FLETYA Pilot: staged sandbox schema only; no live charges or scheduler.
-- Do not apply until compatibility and simulated accounting isolation are verified.
-- Source: scripts/release/activate-stripe-sandbox.sql
alter table public.jobs add column sandbox_payment_method text
  check (sandbox_payment_method in ('card', 'spei'));

create table private.stripe_sandbox_orders (
  id uuid primary key,
  client_id uuid not null references auth.users(id) on delete cascade,
  quote_id uuid not null unique,
  origin text not null,
  destination text not null,
  distance_km numeric not null,
  vehicle text not null,
  helpers integer not null,
  service text not null,
  amount numeric(10,2) not null check (amount > 0),
  method text not null check (method in ('card', 'spei')),
  expires_at timestamptz not null default (now() + interval '1 hour'),
  state text not null default 'pending' check (state in ('pending', 'booked', 'expired', 'review')),
  stripe_session text unique
);
alter table private.stripe_sandbox_orders enable row level security;
revoke all on private.stripe_sandbox_orders from public, anon, authenticated, service_role;
create unique index stripe_sandbox_one_pending on private.stripe_sandbox_orders(client_id)
  where state in ('pending','review');

create function private.guard_sandbox_payment() returns trigger language plpgsql set search_path='' as $$
begin
  if tg_op = 'INSERT' then
    if new.sandbox_payment_method is not null and current_user <> 'postgres' then
      raise insufficient_privilege;
    end if;
  elsif new.sandbox_payment_method is distinct from old.sandbox_payment_method then
    raise insufficient_privilege;
  end if;
  return new;
end $$;
create trigger guard_sandbox_payment before insert or update on public.jobs
for each row execute function private.guard_sandbox_payment();

-- This RPC is callable only by the Edge Function's server-side role.
create function public.stripe_sandbox_order(
  p_action text, p_client uuid, p_id uuid default null, p_quote uuid default null,
  p_vehicle text default null, p_helpers integer default null, p_service text default null,
  p_amount numeric default null, p_method text default null, p_session text default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  attempt private.stripe_sandbox_orders;
  quote public.fletya_route_quotes;
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('fletya-route-order:' || p_client::text, 0));
  if p_action = 'current' then
    select * into attempt from private.stripe_sandbox_orders
      where client_id = p_client and state in ('pending','review');
    if not found then return null; end if;
    return to_jsonb(attempt);
  end if;

  select * into attempt from private.stripe_sandbox_orders where id = p_id and client_id = p_client;
  if p_action = 'reserve' then
    if found then
      if attempt.quote_id is distinct from p_quote or attempt.vehicle is distinct from p_vehicle
         or attempt.helpers is distinct from p_helpers or attempt.service is distinct from p_service
         or attempt.amount is distinct from p_amount or attempt.method is distinct from p_method then
        raise invalid_parameter_value;
      end if;
      return to_jsonb(attempt);
    end if;
    if not exists(select 1 from public.profiles where id=p_client and role='client')
       or p_id is null or p_vehicle is null or p_vehicle not in ('pickup','camioneta','camion')
       or p_helpers is null or p_helpers not between 0 and 2
       or p_service is null or p_service not in ('Mudanza','Paquetería')
       or p_method is null or p_method not in ('card','spei') then
      raise invalid_parameter_value;
    end if;
    select * into quote from public.fletya_route_quotes
      where id = p_quote and client_id = p_client and expires_at > now() for update;
    if not found or exists(select 1 from public.jobs where route_quote_id = p_quote)
       or private.test_route_price(quote.distance_km,p_vehicle,p_helpers) is distinct from p_amount
       or exists(select 1 from public.jobs where client_id = p_client and status in ('requested','accepted','en_route','picked_up')) then
      raise invalid_parameter_value;
    end if;
    insert into private.stripe_sandbox_orders
      (id,client_id,quote_id,origin,destination,distance_km,vehicle,helpers,service,amount,method)
    values (p_id,p_client,p_quote,quote.origin,quote.destination,quote.distance_km,p_vehicle,p_helpers,p_service,p_amount,p_method)
      returning * into attempt;
    return to_jsonb(attempt);
  end if;

  if not found then return null; end if;
  if p_action = 'attach' then
    if attempt.state <> 'pending' or p_session !~ '^cs_test_[A-Za-z0-9]+$'
       or p_session is null or (attempt.stripe_session is not null and attempt.stripe_session <> p_session) then
      raise invalid_parameter_value;
    end if;
    update private.stripe_sandbox_orders set stripe_session = p_session where id = p_id returning * into attempt;
  elsif p_action = 'expire' then
    if attempt.state = 'pending' and (
      (attempt.stripe_session is not null and attempt.stripe_session = p_session)
      or (attempt.stripe_session is null and attempt.expires_at <= now() and p_session is null)
    ) then
      update private.stripe_sandbox_orders set state = 'expired' where id = p_id returning * into attempt;
    end if;
  elsif p_action = 'book' then
    if attempt.stripe_session is null or attempt.stripe_session is distinct from p_session then
      raise invalid_parameter_value;
    end if;
    if attempt.state = 'pending' then
      -- A paid attempt stays visible for review if an older app already placed a job.
      if exists(select 1 from public.jobs where id = attempt.id or route_quote_id = attempt.quote_id
          or (client_id = p_client and status in ('requested','accepted','en_route','picked_up'))) then
        update private.stripe_sandbox_orders set state = 'review' where id = p_id returning * into attempt;
      else
        insert into public.jobs(id,client_id,origin,destination,distance_km,vehicle_type,helpers,service_type,
          price,route_quote_id,test_driver_payout,sandbox_payment_method)
        values(attempt.id,p_client,attempt.origin,attempt.destination,attempt.distance_km,attempt.vehicle,
          attempt.helpers,attempt.service,attempt.amount,
          (select id from public.fletya_route_quotes where id=attempt.quote_id and erase_at>now()),
          case when attempt.vehicle='pickup' then attempt.amount-round(attempt.amount*0.15,2) end,attempt.method);
        update private.stripe_sandbox_orders set state = 'booked' where id = p_id returning * into attempt;
      end if;
    end if;
  elsif p_action <> 'lookup' then
    raise invalid_parameter_value;
  end if;
  return to_jsonb(attempt);
end $$;
revoke all on function public.stripe_sandbox_order(text,uuid,uuid,uuid,text,integer,text,numeric,text,text)
  from public, anon, authenticated, service_role;
grant execute on function public.stripe_sandbox_order(text,uuid,uuid,uuid,text,integer,text,numeric,text,text) to service_role;
notify pgrst, 'reload schema';


-- Source: scripts/release/activate-sandbox-card-authorization.sql
alter table private.stripe_sandbox_orders
  add column card_intent text unique,
  add column hold_until timestamptz,
  add column card_state text check (card_state in ('held','capturing','releasing','paid','released'));

alter table public.jobs add column sandbox_card_state text
  check (sandbox_card_state in ('held','capturing','paid','released'));

create function private.guard_sandbox_card_job() returns trigger
language plpgsql set search_path='' as $$
begin
  if current_user in ('postgres','service_role') then return new; end if;
  if tg_op='INSERT' then
    if new.sandbox_card_state is not null then raise insufficient_privilege; end if;
  elsif new.sandbox_card_state is distinct from old.sandbox_card_state
     or old.sandbox_card_state in ('held','capturing') then
    raise insufficient_privilege using message='El servidor debe confirmar o liberar la autorización de tarjeta.';
  end if;
  if tg_op='UPDATE' and old.status='requested' and new.status='en_route' and new.driver_id is not null then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('fletya-card-driver:' || new.driver_id::text,0));
    if exists(select 1 from public.jobs where driver_id=new.driver_id and status='accepted') then
      raise insufficient_privilege using message='Ya tienes un servicio esperando confirmación del pago.';
    end if;
  end if;
  return new;
end $$;
create trigger guard_sandbox_card_job before insert or update on public.jobs
for each row execute function private.guard_sandbox_card_job();

create function public.stripe_sandbox_card(
  p_action text, p_id uuid, p_actor uuid default null, p_intent text default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  attempt private.stripe_sandbox_orders;
  job public.jobs;
begin
  select * into attempt from private.stripe_sandbox_orders where id=p_id and method='card';
  if not found then return null; end if;
  if p_action in ('claim','resume') then
    if not exists(select 1 from public.profiles where id=p_actor and role='driver' and driver_status='approved') then
      return null;
    end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('fletya-card-driver:' || p_actor::text,0));
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('fletya-route-order:' || attempt.client_id::text,0));
  select * into attempt from private.stripe_sandbox_orders where id=p_id;
  select * into job from public.jobs where id=p_id for update;

  if p_action='authorize' then
    if attempt.client_id is distinct from p_actor or attempt.stripe_session is null
       or p_intent is null or p_intent !~ '^pi_[A-Za-z0-9]+$' then return null; end if;
    if attempt.card_state is null and attempt.state='pending' then
      if job.id is not null or exists(select 1 from public.jobs
         where route_quote_id=attempt.quote_id or (client_id=attempt.client_id
         and status in ('requested','accepted','en_route','picked_up'))) or attempt.expires_at <= now() then
        update private.stripe_sandbox_orders set card_intent=p_intent,card_state='releasing'
          where id=p_id returning * into attempt;
      else
        insert into public.jobs(id,client_id,origin,destination,distance_km,vehicle_type,helpers,service_type,
          price,route_quote_id,test_driver_payout,sandbox_payment_method,sandbox_card_state)
        values(p_id,attempt.client_id,attempt.origin,attempt.destination,attempt.distance_km,attempt.vehicle,
          attempt.helpers,attempt.service,attempt.amount,
          (select id from public.fletya_route_quotes where id=attempt.quote_id and erase_at>now()),
          case when attempt.vehicle='pickup' then attempt.amount-round(attempt.amount*0.15,2) end,'card','held')
        returning * into job;
        update private.stripe_sandbox_orders set state='booked',card_intent=p_intent,card_state='held',
          hold_until=now()+interval '15 minutes' where id=p_id returning * into attempt;
      end if;
    end if;
  elsif p_action='claim' then
    if job.driver_id=p_actor and attempt.card_state in ('capturing','paid') then
      return jsonb_build_object('order',to_jsonb(attempt),'job',to_jsonb(job));
    end if;
    if attempt.card_state is distinct from 'held' or attempt.hold_until <= now()
       or job.status is distinct from 'requested' or job.driver_id is not null
       or exists(select 1 from public.jobs where driver_id=p_actor and status in ('accepted','en_route','picked_up')) then
      return null;
    end if;
    update public.jobs set status='accepted',driver_id=p_actor,sandbox_card_state='capturing'
      where id=p_id returning * into job;
    update private.stripe_sandbox_orders set card_state='capturing' where id=p_id returning * into attempt;
  elsif p_action='resume' then
    if job.driver_id is distinct from p_actor or attempt.card_state is distinct from 'capturing' then return null; end if;
  elsif p_action in ('sweep','cancel') then
    if p_action='cancel' and attempt.client_id is distinct from p_actor then return null; end if;
    if attempt.card_state='held' and (p_action='cancel' or attempt.hold_until <= now()) then
      update public.jobs set status='cancelled' where id=p_id returning * into job;
      update private.stripe_sandbox_orders set card_state='releasing' where id=p_id returning * into attempt;
    end if;
    if p_action='cancel' and attempt.card_state not in ('releasing','released') then return null; end if;
  elsif p_action='captured' then
    if attempt.card_intent is distinct from p_intent then return null; end if;
    if attempt.card_state='capturing' then
      update public.jobs set status='en_route',sandbox_card_state='paid' where id=p_id returning * into job;
      update private.stripe_sandbox_orders set card_state='paid' where id=p_id returning * into attempt;
    end if;
  elsif p_action='released' then
    if attempt.card_intent is distinct from p_intent then return null; end if;
    if attempt.card_state in ('releasing','capturing') then
      update public.jobs set status='cancelled',driver_id=null,sandbox_card_state='released'
        where id=p_id returning * into job;
      update private.stripe_sandbox_orders set state=case when job.id is null then 'expired' else 'booked' end,
        card_state='released' where id=p_id returning * into attempt;
    end if;
  else
    return null;
  end if;
  return jsonb_build_object('order',to_jsonb(attempt),'job',to_jsonb(job));
end $$;
revoke all on function public.stripe_sandbox_card(text,uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.stripe_sandbox_card(text,uuid,uuid,text) to service_role;

-- A private bearer token authorizes only the scheduled reconciliation.
create extension if not exists pg_net;
create table private.stripe_sandbox_scheduler (token uuid primary key default gen_random_uuid());
alter table private.stripe_sandbox_scheduler enable row level security;
revoke all on private.stripe_sandbox_scheduler from public,anon,authenticated,service_role;
insert into private.stripe_sandbox_scheduler default values;
create function public.stripe_sandbox_due(p_token uuid) returns jsonb
language sql security definer set search_path='' as $$
  select coalesce(jsonb_agg(d.id),'[]'::jsonb) from (
    select id from private.stripe_sandbox_orders
    where exists(select 1 from private.stripe_sandbox_scheduler where token=p_token)
      and (card_state in ('capturing','releasing') or (card_state='held' and hold_until <= now()))
    order by hold_until nulls first limit 20
  ) d;
$$;
revoke all on function public.stripe_sandbox_due(uuid) from public,anon,authenticated,service_role;
grant execute on function public.stripe_sandbox_due(uuid) to service_role;
-- Scheduler intentionally deferred until Pilot endpoint and test secret are verified.
notify pgrst,'reload schema';


-- Source: scripts/release/activate-sandbox-card-refunds.sql
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


-- Source: scripts/release/activate-sandbox-refund-review.sql
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


-- Source: supabase/pruebas/guard_cash_stripe_checkout.sql
create function private.guard_cash_stripe_checkout() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  if new.payment_method is distinct from 'cash' then
    return new;
  end if;

  -- Cash booking holds the same per-client lock as Stripe reservation.
  if exists (
    select 1 from private.stripe_sandbox_orders
    where client_id = new.client_id and state in ('pending', 'review')
  ) then
    raise invalid_parameter_value using message = 'Tienes un pago de prueba pendiente o en revisión.';
  end if;
  return new;
end $$;

revoke all on function private.guard_cash_stripe_checkout() from public, anon, authenticated;
create trigger guard_cash_stripe_checkout before insert on public.jobs
for each row execute function private.guard_cash_stripe_checkout();
