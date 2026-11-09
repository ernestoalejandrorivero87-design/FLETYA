-- Vehicle identity is optional for existing profiles. No existing values are changed.
do $migration$
declare before_profiles text;
begin
 perform set_config('lock_timeout','5s',true);
 lock table public.profiles in share row exclusive mode;
 select md5(coalesce(string_agg((to_jsonb(p)-array['vehicle_type','plates'])::text,'' order by id),'')) into before_profiles from public.profiles p;
 alter table public.profiles add column vehicle_type text;
 alter table public.profiles add column plates text;
 alter table public.profiles add constraint driver_vehicle_identity_check check (
  (vehicle_type is null or (role='driver' and vehicle_type in ('pickup','camioneta','camion')))
  and (plates is null or (role='driver' and plates ~ '^[A-Z0-9 -]{3,15}$' and plates=btrim(plates)))
 );
 if before_profiles is distinct from (select md5(coalesce(string_agg((to_jsonb(p)-array['vehicle_type','plates'])::text,'' order by id),'')) from public.profiles p) then
  raise exception 'Existing profile values changed';
 end if;
end $migration$;

-- A narrow RPC avoids exposing profiles (including email/phone) to other users.
create function public.get_assigned_driver(p_job_id uuid)
returns table(driver_id uuid,full_name text,vehicle_type text,plates text)
language sql stable security definer set search_path=''
as $function$
 select d.id,d.full_name,d.vehicle_type,d.plates
 from public.jobs j
 join public.profiles d on d.id=j.driver_id and d.role='driver'
 join public.profiles c on c.id=j.client_id and c.role='client'
 where j.id=p_job_id and j.client_id=(select auth.uid())
 and j.status in ('en_route','picked_up');
$function$;
revoke all on function public.get_assigned_driver(uuid) from public,anon,authenticated;
grant execute on function public.get_assigned_driver(uuid) to authenticated;
notify pgrst, 'reload schema';
