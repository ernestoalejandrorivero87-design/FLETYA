create or replace function private.vehicle_request_matches_v2(p_requested text,p_registered text)
returns boolean language sql immutable set search_path='' as $$
select coalesce(p_requested in ('pickup','estaquita_abierta','estaquita_caja_seca','camion_3_5t')
 and p_registered in ('pickup','estaquita_abierta','estaquita_caja_seca','camion_3_5t')
 and p_requested=p_registered,false);
$$;
revoke all on function private.vehicle_request_matches_v2(text,text) from public,anon,authenticated;