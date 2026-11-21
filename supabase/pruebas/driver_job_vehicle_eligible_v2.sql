create or replace function private.driver_job_vehicle_eligible_v2(p_job uuid,p_driver uuid)
returns boolean language sql stable security invoker set search_path='' as $$
 select exists (
   select 1 from public.jobs j
   join public.profiles p on p.id=p_driver
   where j.id=p_job and j.status='requested' and j.driver_id is null
     and p.role='driver' and p.driver_status='approved'
     and private.vehicle_request_matches_v2(j.vehicle_type,p.vehicle_type)
 );
$$;
revoke all on function private.driver_job_vehicle_eligible_v2(uuid,uuid) from public,anon,authenticated;
