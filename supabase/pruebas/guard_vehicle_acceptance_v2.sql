create or replace function private.guard_vehicle_acceptance_v2() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if old.status='requested' and old.driver_id is null and new.status='en_route' and new.driver_id is not null
    and old.vehicle_type in ('pickup','estaquita_abierta','estaquita_caja_seca','camion_3_5t')
    and coalesce(auth.role(),'') <> 'service_role' then
   if auth.uid() is distinct from new.driver_id or not exists(
      select 1 from public.profiles p where p.id=new.driver_id and p.role='driver'
      and p.driver_status='approved' and private.vehicle_request_matches_v2(old.vehicle_type,p.vehicle_type)
   ) then
      raise exception 'El vehículo registrado no es compatible con esta solicitud';
   end if;
 end if;
 return new;
end $$;
revoke all on function private.guard_vehicle_acceptance_v2() from public,anon,authenticated;
drop trigger if exists guard_vehicle_acceptance_v2 on public.jobs;
create trigger guard_vehicle_acceptance_v2 before update on public.jobs for each row execute function private.guard_vehicle_acceptance_v2();
