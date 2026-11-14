alter table public.jobs
  add column payment_method text check (payment_method = 'cash'),
  add column cash_collected_at timestamptz,
  add column cash_commission_settled_at timestamptz,
  add constraint jobs_cash_payment_state check (
    (cash_collected_at is null or payment_method is not distinct from 'cash')
    and (cash_commission_settled_at is null or cash_collected_at is not null)
    and (payment_method is distinct from 'cash' or not driver_paid)
  );

create function private.guard_job_cash_payment() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  if current_user <> 'postgres' then
    if tg_op = 'INSERT' then
      if new.payment_method is not null or new.cash_collected_at is not null
         or new.cash_commission_settled_at is not null then
        raise insufficient_privilege using message = 'El pago se registra mediante las acciones autorizadas.';
      end if;
    elsif new.payment_method is distinct from old.payment_method
       or new.cash_collected_at is distinct from old.cash_collected_at
       or new.cash_commission_settled_at is distinct from old.cash_commission_settled_at then
      raise insufficient_privilege using message = 'El pago se registra mediante las acciones autorizadas.';
    end if;
  end if;
  return new;
end $$;
revoke all on function private.guard_job_cash_payment() from public, anon, authenticated;
create trigger guard_job_cash_payment before insert or update on public.jobs
for each row execute function private.guard_job_cash_payment();

create function private.confirm_route_quote_with_payment(p_quote uuid, p_request uuid, p_vehicle text, p_helpers integer, p_service text, p_expected_price numeric, p_payment_method text)
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
       and job.service_type = p_service and job.price = p_expected_price and job.payment_method is not distinct from p_payment_method then return to_jsonb(job); end if;
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
  insert into public.jobs(id,client_id,origin,destination,distance_km,vehicle_type,helpers,service_type,price,route_quote_id,test_driver_payout,payment_method)
  values(p_request,actor,saved.origin,saved.destination,saved.distance_km,p_vehicle,p_helpers,p_service,
         total,saved.id,case when p_vehicle='pickup' then total - round(total * 0.15, 2) end,p_payment_method)
  returning * into job;
  return to_jsonb(job);
end $$;

revoke all on function private.confirm_route_quote_with_payment(uuid,uuid,text,integer,text,numeric,text)
  from public, anon, authenticated;

create or replace function private.confirm_test_route_quote(
  p_quote uuid, p_request uuid, p_vehicle text, p_helpers integer, p_service text, p_expected_price numeric
) returns jsonb language sql security definer set search_path = '' as $$
  select private.confirm_route_quote_with_payment(p_quote, p_request, p_vehicle, p_helpers, p_service, p_expected_price, null);
$$;

create function private.confirm_cash_route_quote(
  p_quote uuid, p_request uuid, p_vehicle text, p_helpers integer, p_service text, p_expected_price numeric
) returns jsonb language sql security definer set search_path = '' as $$
  select private.confirm_route_quote_with_payment(p_quote, p_request, p_vehicle, p_helpers, p_service, p_expected_price, 'cash');
$$;

create function public.confirm_cash_route_quote(
  p_quote uuid, p_request uuid, p_vehicle text, p_helpers integer, p_service text, p_expected_price numeric
) returns jsonb language sql security invoker set search_path = '' as $$
  select private.confirm_cash_route_quote(p_quote, p_request, p_vehicle, p_helpers, p_service, p_expected_price);
$$;

create function private.record_cash_payment(p_job uuid, p_event text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  job public.jobs;
begin
  if not private.is_admin() then
    raise insufficient_privilege using message = 'Solo administración puede registrar pagos.';
  end if;

  select * into job from public.jobs where id = p_job for update;
  if not found or job.payment_method is distinct from 'cash' or job.status <> 'completed' or job.driver_id is null then
    raise invalid_parameter_value using message = 'El servicio debe estar completado y pagarse en efectivo.';
  end if;

  case p_event
    when 'collected' then
      if job.cash_collected_at is null then
        update public.jobs set cash_collected_at = now() where id = p_job returning * into job;
      end if;
    when 'commission_settled' then
      if job.cash_collected_at is null then
        raise invalid_parameter_value using message = 'Registra primero el cobro al cliente.';
      end if;
      if job.cash_commission_settled_at is null then
        update public.jobs set cash_commission_settled_at = now() where id = p_job returning * into job;
      end if;
    else
      raise invalid_parameter_value using message = 'Acción de pago inválida.';
  end case;

  return jsonb_build_object('id', job.id, 'cash_collected_at', job.cash_collected_at,
    'cash_commission_settled_at', job.cash_commission_settled_at);
end $$;

create function public.record_cash_payment(p_job uuid, p_event text) returns jsonb
language sql security invoker set search_path = '' as $$
  select private.record_cash_payment(p_job, p_event);
$$;

revoke all on function private.confirm_cash_route_quote(uuid,uuid,text,integer,text,numeric),
  public.confirm_cash_route_quote(uuid,uuid,text,integer,text,numeric),
  private.record_cash_payment(uuid,text), public.record_cash_payment(uuid,text) from public, anon;
grant execute on function private.confirm_cash_route_quote(uuid,uuid,text,integer,text,numeric),
  public.confirm_cash_route_quote(uuid,uuid,text,integer,text,numeric),
  private.record_cash_payment(uuid,text), public.record_cash_payment(uuid,text) to authenticated;

notify pgrst, 'reload schema';
