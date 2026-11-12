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
     or p_service is null or p_service not in ('Mudanza','Paquetería')
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
  if exists(select 1 from public.jobs where client_id = actor and status in ('requested','en_route','picked_up')) then
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
