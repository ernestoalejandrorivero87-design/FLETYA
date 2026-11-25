-- PRUEBAS ONLY. Review and apply only to project ccdtpwvalqznasstnqxj.
begin;
create table private.vehicle_tariff_history_v1 (
 id bigint generated always as identity primary key,
 vehicle_code text not null,
 previous_values jsonb not null,
 new_values jsonb not null,
 reason text not null check (length(trim(reason)) between 3 and 500),
 changed_by uuid not null,
 changed_at timestamptz not null default clock_timestamp()
);
alter table private.vehicle_tariff_history_v1 enable row level security;
revoke all on private.vehicle_tariff_history_v1 from public, anon, authenticated;
create function private.admin_vehicle_tariffs_v1() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not coalesce(private.is_admin(),false) then raise insufficient_privilege; end if;
 return (select coalesce(jsonb_agg(to_jsonb(t) order by vehicle_code),'[]'::jsonb) from private.vehicle_tariff_drafts_v1 t);
end; $$;
create function private.admin_update_vehicle_tariff_v1(p_vehicle text,p_minimum numeric,p_per_km numeric,p_included numeric,p_reason text,p_expected_updated_at timestamptz) returns jsonb
language plpgsql security definer set search_path='' as $$
declare old_row private.vehicle_tariff_drafts_v1%rowtype; new_row private.vehicle_tariff_drafts_v1%rowtype;
begin
 if auth.uid() is null or not coalesce(private.is_admin(),false) then raise insufficient_privilege; end if;
 if p_vehicle is null or p_vehicle not in ('pickup','estaquita_abierta','estaquita_caja_seca','camion_3_5t') or p_minimum is null or not (p_minimum between 1 and 100000) or p_per_km is null or not (p_per_km between 0 and 10000) or p_included is null or not (p_included between 0 and 100) or length(trim(coalesce(p_reason,''))) not between 3 and 500 then raise invalid_parameter_value; end if;
 select * into strict old_row from private.vehicle_tariff_drafts_v1 where vehicle_code=p_vehicle for update;
 if old_row.updated_at is distinct from p_expected_updated_at then raise exception 'La tarifa cambió; vuelve a consultar.'; end if;
 update private.vehicle_tariff_drafts_v1 set minimum_price=p_minimum,price_per_km=p_per_km,included_km=p_included,updated_at=clock_timestamp() where vehicle_code=p_vehicle returning * into new_row;
 insert into private.vehicle_tariff_history_v1(vehicle_code,previous_values,new_values,reason,changed_by) values(p_vehicle,to_jsonb(old_row),to_jsonb(new_row),trim(p_reason),auth.uid());
 return to_jsonb(new_row);
end; $$;
create function public.admin_vehicle_tariffs_v1() returns jsonb language sql stable security invoker set search_path='' as $$ select private.admin_vehicle_tariffs_v1(); $$;
create function public.admin_update_vehicle_tariff_v1(p_vehicle text,p_minimum numeric,p_per_km numeric,p_included numeric,p_reason text,p_expected_updated_at timestamptz) returns jsonb language sql security invoker set search_path='' as $$ select private.admin_update_vehicle_tariff_v1(p_vehicle,p_minimum,p_per_km,p_included,p_reason,p_expected_updated_at); $$;
revoke all on function private.admin_vehicle_tariffs_v1(), public.admin_vehicle_tariffs_v1(), private.admin_update_vehicle_tariff_v1(text,numeric,numeric,numeric,text,timestamptz), public.admin_update_vehicle_tariff_v1(text,numeric,numeric,numeric,text,timestamptz) from public,anon,authenticated;
grant execute on function private.admin_vehicle_tariffs_v1(), public.admin_vehicle_tariffs_v1(), private.admin_update_vehicle_tariff_v1(text,numeric,numeric,numeric,text,timestamptz), public.admin_update_vehicle_tariff_v1(text,numeric,numeric,numeric,text,timestamptz) to authenticated;
commit;
