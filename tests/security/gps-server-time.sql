-- Rollback-only tests; existing roles, no Auth or profile changes.
begin;
set local lock_timeout='3s';
set local statement_timeout='20s';
select set_config('gps_test.client',(select id::text from public.profiles where role='client' order by id limit 1),true);
select set_config('gps_test.driver',(select id::text from public.profiles where role='driver' order by id limit 1),true);
select set_config('gps_test.job',gen_random_uuid()::text,true);
select set_config('request.jwt.claim.role','service_role',true);
select set_config('request.jwt.claims','{"role":"service_role"}',true);
insert into public.jobs(id,origin,destination,price,status,client_id,driver_id)
values(current_setting('gps_test.job')::uuid,'GPS test A','GPS test B',100,'en_route',current_setting('gps_test.client')::uuid,current_setting('gps_test.driver')::uuid);
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub',current_setting('gps_test.driver'),true);
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',current_setting('gps_test.driver'))::text,true);
insert into public.driver_locations(driver_id,job_id,latitude,longitude,accuracy,updated_at)
values(auth.uid(),current_setting('gps_test.job')::uuid,21.1,-86.8,10,now()+interval '1 hour')
on conflict(driver_id) do update set job_id=excluded.job_id,latitude=excluded.latitude,longitude=excluded.longitude,updated_at=excluded.updated_at;
do $$ begin
 if not exists(select 1 from public.driver_locations where driver_id=auth.uid() and abs(extract(epoch from(clock_timestamp()-updated_at)))<5) then raise exception 'Future client time was accepted';end if;
end $$;
update public.driver_locations set latitude=21.2,updated_at=now()-interval '2 days' where driver_id=auth.uid();
do $$ begin
 if not exists(select 1 from public.driver_locations where driver_id=auth.uid() and latitude=21.2 and abs(extract(epoch from(clock_timestamp()-updated_at)))<5) then raise exception 'Past client time was accepted';end if;
end $$;
update public.driver_locations set latitude=21.3 where driver_id=auth.uid();
do $$ begin
 if not exists(select 1 from public.driver_locations where driver_id=auth.uid() and latitude=21.3 and abs(extract(epoch from(clock_timestamp()-updated_at)))<5) then raise exception 'Omitted client time did not get stamped';end if;
end $$;
reset role;
do $$ begin
 if has_function_privilege('authenticated','private.stamp_driver_location_received_at()','EXECUTE') or has_function_privilege('anon','private.stamp_driver_location_received_at()','EXECUTE') then raise exception 'Trigger-only timestamp function is executable';end if;
end $$;
select 'GPS server reception timestamps passed; changes rolled back' as result;
rollback;
