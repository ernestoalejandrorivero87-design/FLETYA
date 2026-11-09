-- Use server time for the age calculation without expanding location visibility.
create function public.get_job_driver_location(p_job_id uuid)
returns table(job_id uuid,driver_id uuid,latitude double precision,longitude double precision,accuracy double precision,updated_at timestamptz,server_now timestamptz)
language sql stable security invoker set search_path=''
as $function$
 select l.job_id,l.driver_id,l.latitude,l.longitude,l.accuracy,l.updated_at,statement_timestamp()
 from public.driver_locations l
 join public.jobs j on j.id=l.job_id and j.driver_id=l.driver_id
 where j.id=p_job_id and j.status in ('en_route','picked_up')
 and (j.client_id=(select auth.uid()) or j.driver_id=(select auth.uid()));
$function$;
revoke all on function public.get_job_driver_location(uuid) from public,anon,authenticated;
grant execute on function public.get_job_driver_location(uuid) to authenticated;
notify pgrst, 'reload schema';
