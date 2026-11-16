-- Apply only to FLETYA Pruebas (ccdtpwvalqznasstnqxj).
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
