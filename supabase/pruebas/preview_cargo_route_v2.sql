create function private.preview_cargo_route_v2(p_quote uuid,p_category text,p_helpers integer,p_pickup_level integer,p_pickup_elevator boolean,p_dropoff_level integer,p_dropoff_elevator boolean) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare km numeric;
begin
if auth.uid() is null then raise exception 'Sesión requerida'; end if;
select q.distance_km into km from public.fletya_route_quotes q join public.profiles p on p.id=q.client_id where q.id=p_quote and q.client_id=auth.uid() and p.role='client' and q.expires_at>now();
if not found then raise exception 'Ruta no disponible o vencida'; end if;
return private.cargo_price_preview_v2(km,p_category,p_helpers,p_pickup_level,p_pickup_elevator,p_dropoff_level,p_dropoff_elevator) || jsonb_build_object('route_quote_id',p_quote,'preview_only',true);
end;$$;
revoke all on function private.preview_cargo_route_v2(uuid,text,integer,integer,boolean,integer,boolean) from public,anon,authenticated;
grant execute on function private.preview_cargo_route_v2(uuid,text,integer,integer,boolean,integer,boolean) to authenticated;
create function public.preview_cargo_route_v2(p_quote uuid,p_category text,p_helpers integer,p_pickup_level integer,p_pickup_elevator boolean,p_dropoff_level integer,p_dropoff_elevator boolean) returns jsonb language sql stable security invoker set search_path='' as $$ select private.preview_cargo_route_v2(p_quote,p_category,p_helpers,p_pickup_level,p_pickup_elevator,p_dropoff_level,p_dropoff_elevator); $$;
revoke all on function public.preview_cargo_route_v2(uuid,text,integer,integer,boolean,integer,boolean) from public,anon,authenticated;
grant execute on function public.preview_cargo_route_v2(uuid,text,integer,integer,boolean,integer,boolean) to authenticated;