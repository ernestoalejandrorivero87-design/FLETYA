create function private.cargo_price_preview_v2(p_km numeric,p_category text,p_helpers integer,p_pickup_level integer,p_pickup_elevator boolean,p_dropoff_level integer,p_dropoff_elevator boolean) returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare t public.fletya_tariff_versions%rowtype; b numeric; k numeric; distance_cost numeric; helper_cost numeric; pickup_cost numeric; dropoff_cost numeric; total numeric; commission numeric;
begin
if p_km is null or p_km<0 or p_km>1000 or p_category is null or p_category not in ('Paquetería','Mudanza','Materiales') or p_helpers is null or p_helpers not between 0 and 3 or p_pickup_level is null or p_pickup_level not between 0 and 100 or p_dropoff_level is null or p_dropoff_level not between 0 and 100 or p_pickup_elevator is null or p_dropoff_elevator is null then raise exception 'Datos de cotización inválidos'; end if;
select * into t from public.fletya_tariff_versions where effective_at<=now() order by effective_at desc,created_at desc,id desc limit 1;
if not found or t.stair_per_level is null or t.elevator_per_site is null or t.free_wait_minutes is null or t.wait_per_minute is null then raise exception 'Configuración incompleta'; end if;
b:=case p_category when 'Paquetería' then t.parcel_base when 'Mudanza' then t.moving_base else t.materials_base end;
k:=case p_category when 'Paquetería' then t.parcel_km when 'Mudanza' then t.moving_km else t.materials_km end;
distance_cost:=round(greatest(p_km-t.included_km,0)*k,2);
helper_cost:=p_helpers*t.helper_price;
pickup_cost:=case when p_pickup_level=0 then 0 when p_pickup_elevator then t.elevator_per_site else p_pickup_level*t.stair_per_level end;
dropoff_cost:=case when p_dropoff_level=0 then 0 when p_dropoff_elevator then t.elevator_per_site else p_dropoff_level*t.stair_per_level end;
total:=round(b+distance_cost+helper_cost+pickup_cost+dropoff_cost,2);commission:=round(total*t.commission_percent/100,2);
return jsonb_build_object('tariff_version',t.id,'category',p_category,'distance_km',p_km,'base',b,'distance_extra',distance_cost,'helpers',helper_cost,'pickup_access',pickup_cost,'dropoff_access',dropoff_cost,'total',total,'commission',commission,'driver_gross',total-commission,'helper_hours',t.helper_hours,'helper_overtime',t.helper_overtime,'free_wait_minutes',t.free_wait_minutes,'wait_per_minute',t.wait_per_minute);
end;$$;
revoke all on function private.cargo_price_preview_v2(numeric,text,integer,integer,boolean,integer,boolean) from public,anon,authenticated;