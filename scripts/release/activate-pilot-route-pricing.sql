create table public.fletya_route_quotes (
  id uuid primary key,
  client_id uuid not null references auth.users(id) on delete cascade,
  origin text not null,
  destination text not null,
  distance_km numeric(9,2) not null check (distance_km > 0),
  points jsonb not null check (jsonb_typeof(points) = 'array' and jsonb_array_length(points) >= 2),
  via jsonb not null default '[]' check (jsonb_typeof(via) = 'array' and jsonb_array_length(via) <= 3),
  expires_at timestamptz not null default (now() + interval '10 minutes'),
  erase_at timestamptz not null default (now() + interval '7 days')
);
alter table public.fletya_route_quotes enable row level security;
revoke all on public.fletya_route_quotes from public, anon, authenticated, service_role;
grant insert on public.fletya_route_quotes to service_role;
create index fletya_route_quotes_expiry on public.fletya_route_quotes(expires_at);

alter table public.jobs add column route_quote_id uuid;
create unique index jobs_route_quote_id_unique on public.jobs(route_quote_id) where route_quote_id is not null;

create function private.guard_job_route_quote() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
  if tg_op = 'INSERT' then
    if new.route_quote_id is not null and current_user <> 'postgres' then
      raise insufficient_privilege using message='La ruta se vincula al confirmar la cotización.';
    end if;
  elsif new.route_quote_id is distinct from old.route_quote_id then
    raise insufficient_privilege using message='La ruta vinculada al servicio es de solo lectura.';
  end if;
  return new;
end $$;
revoke all on function private.guard_job_route_quote() from public, anon, authenticated;
create trigger guard_job_route_quote before insert or update of route_quote_id on public.jobs
for each row execute function private.guard_job_route_quote();

create function private.get_job_delivery_route(p_job uuid)
returns jsonb language sql stable security definer set search_path='' as $$
  select case when j.route_quote_id is null then jsonb_build_object('bound',false)
              when q.id is null then jsonb_build_object('bound',true,'available',false)
              else jsonb_build_object('bound',true,'available',true,'distance_km',j.distance_km,'points',q.points,'via',q.via)
         end
  from public.jobs j
  left join public.fletya_route_quotes q on q.id=j.route_quote_id and q.erase_at>now()
  where j.id=p_job and (j.client_id=auth.uid() or
    (j.driver_id=auth.uid() and j.status in ('en_route','picked_up')
      and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='driver' and p.driver_status='approved')));
$$;

create function public.get_job_delivery_route(p_job uuid)
returns jsonb language sql stable security invoker set search_path='' as $$
  select private.get_job_delivery_route(p_job);
$$;

revoke all on function private.get_job_delivery_route(uuid), public.get_job_delivery_route(uuid) from public, anon;
grant execute on function private.get_job_delivery_route(uuid), public.get_job_delivery_route(uuid) to authenticated;

notify pgrst,'reload schema';

alter table public.jobs add column test_driver_payout numeric(10,2);

create function private.guard_test_driver_payout() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
  if tg_op = 'INSERT' then
    if new.test_driver_payout is not null and current_user <> 'postgres' then
      raise insufficient_privilege using message='La liquidación se calcula al confirmar la cotización.';
    end if;
  elsif new.test_driver_payout is distinct from old.test_driver_payout then
    raise insufficient_privilege using message='La liquidación confirmada es de solo lectura.';
  end if;
  return new;
end $$;
revoke all on function private.guard_test_driver_payout() from public, anon, authenticated;
create trigger guard_test_driver_payout before insert or update of test_driver_payout on public.jobs
for each row execute function private.guard_test_driver_payout();

create function private.test_route_price(km numeric, vehicle text, helpers integer)
returns numeric language sql immutable strict set search_path='' as $$
  select round(case vehicle
    when 'pickup' then 400 + greatest(km - 3, 0) * 35
    when 'camioneta' then 220 + km * 45
    when 'camion' then 420 + km * 65
  end + helpers * 180, 2);
$$;
revoke all on function private.test_route_price(numeric,text,integer) from public, anon, authenticated;

create function private.preview_test_route_price(p_quote uuid, p_vehicle text, p_helpers integer)
returns numeric language sql stable security definer set search_path='' as $$
  select private.test_route_price(q.distance_km, p_vehicle, p_helpers)
  from public.fletya_route_quotes q
  where q.id = p_quote and q.client_id = (select auth.uid())
    and q.expires_at > now() and p_helpers between 0 and 2
    and exists (select 1 from public.profiles p where p.id=q.client_id and p.role='client');
$$;
create function public.preview_test_route_price(p_quote uuid, p_vehicle text, p_helpers integer)
returns numeric language sql stable security invoker set search_path='' as $$
  select private.preview_test_route_price(p_quote,p_vehicle,p_helpers);
$$;

create function private.confirm_test_route_quote(p_quote uuid, p_request uuid, p_vehicle text, p_helpers integer, p_service text, p_expected_price numeric)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  actor uuid := auth.uid();
  saved public.fletya_route_quotes;
  job public.jobs;
  total numeric;
begin
  if actor is null or not exists(select 1 from public.profiles where id = actor and role = 'client') then
    raise insufficient_privilege using message='Inicia sesión como cliente.';
  end if;
  if p_quote is null or p_request is null or p_helpers is null or p_helpers not between 0 and 2
     or p_service is null or p_service not in ('Mudanza','Flete de muebles','Materiales','Paquetería')
     or p_vehicle is null or p_vehicle not in ('pickup','camioneta','camion') then
    raise invalid_parameter_value using message='Revisa el vehículo, los ayudantes y el tipo de servicio.';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('fletya-route-order:' || actor::text, 0));
  select * into job from public.jobs where id = p_request and client_id = actor;
  if found then
    if job.route_quote_id = p_quote and job.vehicle_type = p_vehicle and job.helpers = p_helpers
       and job.service_type = p_service and job.price = p_expected_price then return to_jsonb(job); end if;
    raise unique_violation using message='El identificador ya corresponde a otra solicitud.';
  end if;
  select * into saved from public.fletya_route_quotes where id = p_quote and client_id = actor for update;
  if not found or saved.expires_at <= clock_timestamp() then
    raise invalid_parameter_value using message='La cotización ya no está disponible. Calcula la ruta de nuevo.';
  end if;
  if exists(select 1 from public.jobs where route_quote_id = p_quote) then
    raise unique_violation using message='La cotización ya se usó para un servicio.';
  end if;
  if exists(select 1 from public.jobs where client_id = actor and status in ('requested','accepted','en_route','picked_up')) then
    raise unique_violation using message='Ya tienes un servicio activo.';
  end if;

  total := private.test_route_price(saved.distance_km, p_vehicle, p_helpers);
  if total is distinct from p_expected_price then
    raise invalid_parameter_value using message='El precio cambió. Calcula de nuevo antes de confirmar.';
  end if;
  insert into public.jobs(id,client_id,origin,destination,distance_km,vehicle_type,helpers,service_type,price,route_quote_id,test_driver_payout)
  values(p_request,actor,saved.origin,saved.destination,saved.distance_km,p_vehicle,p_helpers,p_service,
         total,saved.id,case when p_vehicle='pickup' then total - round(total * 0.15, 2) end)
  returning * into job;
  return to_jsonb(job);
end $$;

create function public.confirm_test_route_quote(p_quote uuid, p_request uuid, p_vehicle text,
  p_helpers integer, p_service text, p_expected_price numeric)
returns jsonb language sql security invoker set search_path='' as $$
  select private.confirm_test_route_quote(p_quote,p_request,p_vehicle,p_helpers,p_service,p_expected_price);
$$;

revoke all on function private.preview_test_route_price(uuid,text,integer),
  public.preview_test_route_price(uuid,text,integer),
  private.confirm_test_route_quote(uuid,uuid,text,integer,text,numeric),
  public.confirm_test_route_quote(uuid,uuid,text,integer,text,numeric) from public, anon;
grant execute on function private.preview_test_route_price(uuid,text,integer),
  public.preview_test_route_price(uuid,text,integer),
  private.confirm_test_route_quote(uuid,uuid,text,integer,text,numeric),
  public.confirm_test_route_quote(uuid,uuid,text,integer,text,numeric) to authenticated;
notify pgrst, 'reload schema';

create extension if not exists pg_cron;

-- Delete route coordinates shortly after the booking or delivery retention window.
select cron.schedule('fletya-purge-expired-route-coordinates', '17 * * * *', $$
  delete from public.fletya_route_quotes q
  where q.erase_at <= now()
     or (q.expires_at <= now() and not exists (
       select 1 from public.jobs j where j.route_quote_id = q.id
     ));
$$);

