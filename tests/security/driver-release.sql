-- Rollback-only pickup/release checks against existing account roles; no Auth records are written.
begin;
set local lock_timeout='3s';
set local statement_timeout='20s';
create temporary table release_cases(label text primary key,id uuid default gen_random_uuid()) on commit drop;
insert into release_cases(label) values('flow'),('release'),('protected'),('foreign');
select set_config('fletya.release_client',(select id::text from public.profiles where role='client' order by id limit 1),true);
select set_config('fletya.release_driver',(select id::text from public.profiles where role='driver' order by id limit 1),true);
select set_config('fletya.release_other',(select id::text from public.profiles where role='admin' order by id limit 1),true);
select set_config('fletya.release_ids',(select jsonb_object_agg(label,id)::text from release_cases),true);
select set_config('request.jwt.claim.role','service_role',true);
select set_config('request.jwt.claims','{"role":"service_role"}',true);
insert into public.jobs(id,origin,destination,price,status,client_id,driver_id)
 select id,'Release test origin','Release test destination',400,'en_route',current_setting('fletya.release_client')::uuid,
 case when label='foreign' then current_setting('fletya.release_other') else current_setting('fletya.release_driver') end::uuid
 from release_cases;
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub',current_setting('fletya.release_driver'),true);
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',current_setting('fletya.release_driver'))::text,true);
do $$
declare ids jsonb:=current_setting('fletya.release_ids')::jsonb; n integer; test_reason text;
begin
 begin
  update public.jobs set status='completed' where id=(ids->>'protected')::uuid;
  raise exception 'TESTFAIL: completion skipped pickup';
 exception when raise_exception then
  if sqlerrm not like 'Drivers may only accept requests%' then raise; end if;
 end;
 update public.jobs set status='picked_up' where id=(ids->>'flow')::uuid;
 get diagnostics n=row_count;
 if n<>1 then raise exception 'Pickup failed'; end if;
 insert into public.driver_locations(driver_id,job_id,latitude,longitude) values(auth.uid(),(ids->>'flow')::uuid,21,-86)
  on conflict(driver_id) do update set job_id=excluded.job_id,latitude=excluded.latitude,longitude=excluded.longitude;
 update public.driver_locations set latitude=21.1 where driver_id=auth.uid();
 begin
  update public.jobs set status='requested',driver_id=null,release_reason='Cannot proceed with this job' where id=(ids->>'flow')::uuid;
  raise exception 'TESTFAIL: released picked-up cargo';
 exception when raise_exception then
  if sqlerrm not like 'Drivers may only accept requests%' then raise; end if;
 end;
 update public.jobs set status='completed' where id=(ids->>'flow')::uuid;
 if not exists(select 1 from public.jobs where id=(ids->>'flow')::uuid and status='completed') then raise exception 'Completion after pickup failed'; end if;
 foreach test_reason in array array['','short'] loop
  begin
   update public.jobs set status='requested',driver_id=null,release_reason=test_reason where id=(ids->>'release')::uuid;
   raise exception 'TESTFAIL: released without a valid reason';
  exception when raise_exception then
   if sqlerrm not like 'Drivers may only accept requests%' then raise; end if;
  end;
 end loop;
 begin
  update public.jobs set status='requested',driver_id=null,release_reason='Cannot proceed with this job',price=1 where id=(ids->>'protected')::uuid;
  raise exception 'TESTFAIL: release edited price';
 exception when raise_exception then
  if sqlerrm not like 'Drivers cannot edit job details%' then raise; end if;
 end;
 update public.jobs set status='requested',driver_id=null,release_reason='Cannot proceed with this job' where id=(ids->>'foreign')::uuid;
 get diagnostics n=row_count;
 if n<>0 then raise exception 'Released another driver job'; end if;
 insert into public.driver_locations(driver_id,job_id,latitude,longitude) values(auth.uid(),(ids->>'release')::uuid,21,-86)
  on conflict(driver_id) do update set job_id=excluded.job_id,latitude=excluded.latitude,longitude=excluded.longitude;
 update public.jobs set status='requested',driver_id=null,release_reason='  Vehicle needs a repair  ' where id=(ids->>'release')::uuid and driver_id=auth.uid() and status='en_route';
 get diagnostics n=row_count;
 if n<>1 then raise exception 'Release failed'; end if;
 if not exists(select 1 from public.job_driver_releases where job_id=(ids->>'release')::uuid and driver_id=auth.uid() and reason='Vehicle needs a repair') then raise exception 'Release audit missing or untrimmed'; end if;
 begin
  update public.driver_locations set latitude=22 where driver_id=auth.uid();
  raise exception 'TESTFAIL: GPS continued after release';
 exception when insufficient_privilege then null;
 end;
 begin
  insert into public.job_driver_releases(job_id,driver_id,origin,destination,reason) values((ids->>'release')::uuid,auth.uid(),'A','B','Forged audit record');
  raise exception 'TESTFAIL: driver forged audit';
 exception when insufficient_privilege then null;
 end;
 begin
  update public.job_driver_releases set reason='Modified release record' where driver_id=auth.uid();
  raise exception 'TESTFAIL: driver changed audit';
 exception when insufficient_privilege then null;
 end;
end $$;
select set_config('request.jwt.claim.sub',current_setting('fletya.release_client'),true);
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',current_setting('fletya.release_client'))::text,true);
do $$
declare ids jsonb:=current_setting('fletya.release_ids')::jsonb;
begin
 if not exists(select 1 from public.jobs where id=(ids->>'release')::uuid and status='requested' and driver_id is null and price=400) then raise exception 'Client did not recover unassigned request'; end if;
 if not exists(select 1 from public.job_driver_releases where job_id=(ids->>'release')::uuid) then raise exception 'Client cannot view own release audit'; end if;
 if exists(select 1 from public.driver_locations where job_id=(ids->>'release')::uuid) then raise exception 'Client still sees released driver GPS'; end if;
end $$;
reset role;
-- Trusted fixture reassignment to another existing identity tests GPS ownership independently of driver UI.
select set_config('request.jwt.claim.role','service_role',true);
select set_config('request.jwt.claims','{"role":"service_role"}',true);
update public.jobs set status='en_route',driver_id=current_setting('fletya.release_other')::uuid
 where id=(current_setting('fletya.release_ids')::jsonb->>'release')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub',current_setting('fletya.release_client'),true);
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',current_setting('fletya.release_client'))::text,true);
do $$ begin
 if exists(select 1 from public.driver_locations where job_id=(current_setting('fletya.release_ids')::jsonb->>'release')::uuid) then raise exception 'Previous driver GPS leaked after reassignment'; end if;
end $$;
select set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',current_setting('request.jwt.claim.sub'))::text,true);
do $$ begin
 if exists(select 1 from public.job_driver_releases where job_id=(current_setting('fletya.release_ids')::jsonb->>'release')::uuid) then raise exception 'Nonparticipant sees release audit'; end if;
end $$;
reset role;
do $$ begin
 if has_function_privilege('authenticated','private.record_job_driver_release()','EXECUTE') then raise exception 'Audit trigger is directly executable'; end if;
 if has_table_privilege('anon','public.job_driver_releases','SELECT') then raise exception 'Anonymous audit access'; end if;
end $$;
select 'FLETYA driver release and pickup checks passed; synthetic changes rolled back' as result;
rollback;
