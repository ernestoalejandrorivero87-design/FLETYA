-- New GPS writes use server reception time. Historical records are left untouched.
create function private.stamp_driver_location_received_at()
returns trigger language plpgsql security invoker set search_path=''
as $function$
begin
 new.updated_at := clock_timestamp();
 return new;
end;
$function$;
revoke all on function private.stamp_driver_location_received_at() from public,anon,authenticated;
create trigger stamp_driver_location_received_at before insert or update on public.driver_locations
 for each row execute function private.stamp_driver_location_received_at();
