-- Rollback-only fixture; no Auth/profile changes.
begin;
set local lock_timeout='3s';
set local statement_timeout='20s';
select set_config('fresh.client',(select id::text from public.profiles where role='client' order by id limit 1),true);
select set_config('fresh.driver',(select id::text from public.profiles where role='driver' order by id limit 1),true);
select set_config('fresh.other',(select id::text from public.profiles where role='admin' order by id limit 1),true);
select set_config('fresh.job',gen_random_uuid()::text,true);
select set_config('request.jwt.claim.role','service_role',true);
select set_config('request.jwt.claims','{"role":"service_role"}',true);
insert into public.jobs(id,origin,destination,price,status,client_id,driver_id)
values(current_setting('fresh.job')::uuid,'Fresh test A','Fresh test B',100,'en_route',current_setting('fresh.client')::uuid,current_setting('fresh.driver')::uuid);
insert into public.driver_locations(driver_id,job_id,latitude,longitude,accuracy)
values(current_setting('fresh.driver')::uuid,current_setting('fresh.job')::uuid,21.1,-86.8,20)
on conflict(driver_id) do update set job_id=excluded.job_id,latitude=excluded.latitude,longitude=excluded.longitude,accuracy=excluded.accuracy;
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub',current_setting('fresh.client'),true);
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',current_setting('fresh.client'))::text,true);
do $$ declare r record;begin
 select * into r from public.get_job_driver_location(current_setting('fresh.job')::uuid);
 if r.driver_id is distinct from current_setting('fresh.driver')::uuid or r.job_id is distinct from current_setting('fresh.job')::uuid or abs(extract(epoch from(r.server_now-r.updated_at)))>5 then raise exception 'Owned location/server time incorrect';end if;
 if exists(select 1 from public.get_job_driver_location(gen_random_uuid()))then raise exception 'Unknown job leaked location';end if;
end $$;
select set_config('request.jwt.claim.sub',current_setting('fresh.other'),true);
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',current_setting('fresh.other'))::text,true);
do $$begin
 if exists(select 1 from public.get_job_driver_location(current_setting('fresh.job')::uuid))then raise exception 'Nonparticipant read location';end if;
end $$;
select set_config('request.jwt.claim.sub',current_setting('fresh.driver'),true);
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',current_setting('fresh.driver'))::text,true);
do $$begin
 if not exists(select 1 from public.get_job_driver_location(current_setting('fresh.job')::uuid))then raise exception 'Assigned driver lost own GPS access';end if;
end $$;
reset role;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('request.jwt.claims','{"role":"service_role"}',true);
-- Test old driver row hidden after reassignment, even from its owning driver account.
update public.jobs set driver_id=current_setting('fresh.other')::uuid where id=current_setting('fresh.job')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',current_setting('fresh.driver'))::text,true);
do $$begin
 if exists(select 1 from public.get_job_driver_location(current_setting('fresh.job')::uuid))then raise exception 'Old driver GPS leaked after reassignment';end if;
end $$;
reset role;
do $$begin
 if has_function_privilege('anon','public.get_job_driver_location(uuid)','EXECUTE') then raise exception 'Anonymous RPC execution';end if;
 if (select prosecdef from pg_proc where oid='public.get_job_driver_location(uuid)'::regprocedure) then raise exception 'Location RPC bypasses RLS';end if;
end $$;
select 'Server-referenced location freshness and RLS passed; changes rolled back' as result;
rollback;
