-- FLETYA Pruebas only. Run after activate-stripe-sandbox.sql.
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
select cron.schedule('fletya-stripe-sandbox-reconcile','* * * * *',$cron$
  select net.http_post(
    url := 'https://ccdtpwvalqznasstnqxj.supabase.co/functions/v1/fletya-stripe-sandbox',
    headers := jsonb_build_object('Content-Type','application/json','X-Fletya-Schedule',
      (select token::text from private.stripe_sandbox_scheduler limit 1)),
    body := '{"action":"sweep"}'::jsonb, timeout_milliseconds := 20000
  );
$cron$);
notify pgrst,'reload schema';
