-- Disposable PostgreSQL smoke/integration checks. Run only in CI's throwaway database.
\set ON_ERROR_STOP on

-- Install the auth.users trigger after the migration has defined handle_new_user().
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

insert into auth.users(id, raw_user_meta_data) values
('10000000-0000-0000-0000-000000000001', '{"full_name":"Client test","role":"client"}'),
('20000000-0000-0000-0000-000000000002', '{"full_name":"Driver test","role":"driver"}'),
('30000000-0000-0000-0000-000000000003', '{"full_name":"Admin spoof test","role":"admin"}');

do $$
begin
  if (select role from public.profiles where id='10000000-0000-0000-0000-000000000001') <> 'client' then
    raise exception 'client signup role mismatch';
  end if;
  if (select role from public.profiles where id='20000000-0000-0000-0000-000000000002') <> 'driver' then
    raise exception 'driver signup role mismatch';
  end if;
  if (select role from public.profiles where id='30000000-0000-0000-0000-000000000003') <> 'client' then
    raise exception 'admin metadata escalation was not blocked';
  end if;
end $$;

-- Seed one requested job through the trusted service-role path.
select set_config('request.jwt.claim.role','service_role',false);
insert into public.jobs(id,origin,destination,distance_km,vehicle_type,helpers,service_type,description,price,status,client_id)
values ('40000000-0000-0000-0000-000000000004','A','B',5,'pickup',0,'flete','test',100,'requested','10000000-0000-0000-0000-000000000001');
select set_config('request.jwt.claim.role','',false);

-- A client cannot promote their own profile to admin.
set role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000001',false);
select set_config('request.jwt.claim.role','authenticated',false);
do $$
begin
  begin
    update public.profiles set role='admin' where id=auth.uid();
    raise exception 'profile role escalation unexpectedly succeeded';
  exception when others then
    if sqlerrm = 'profile role escalation unexpectedly succeeded' then raise; end if;
  end;
end $$;
reset role;

-- The driver can accept the request but cannot change the price or payment flag.
set role authenticated;
select set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000002',false);
select set_config('request.jwt.claim.role','authenticated',false);
update public.jobs set status='en_route', driver_id=auth.uid()
where id='40000000-0000-0000-0000-000000000004';
do $$
begin
  begin
    update public.jobs set price=9999 where id='40000000-0000-0000-0000-000000000004';
    raise exception 'driver price modification unexpectedly succeeded';
  exception when others then
    if sqlerrm = 'driver price modification unexpectedly succeeded' then raise; end if;
  end;
  begin
    update public.jobs set driver_paid=true where id='40000000-0000-0000-0000-000000000004';
    raise exception 'driver payment modification unexpectedly succeeded';
  exception when others then
    if sqlerrm = 'driver payment modification unexpectedly succeeded' then raise; end if;
  end;
end $$;
-- Fletero can write GPS only for their own active job.
insert into public.driver_locations(driver_id,job_id,latitude,longitude)
values (auth.uid(),'40000000-0000-0000-0000-000000000004',19.4,-99.1);
update public.jobs set status='completed' where id='40000000-0000-0000-0000-000000000004';
reset role;

-- A completed job can be marked paid by an admin; unrelated edits remain forbidden.
-- Clear the simulated user JWT before seeding the trusted admin fixture as the database owner.
select set_config('request.jwt.claim.sub','',false);
select set_config('request.jwt.claim.role','',false);
insert into public.profiles(id,full_name,role) values ('50000000-0000-0000-0000-000000000005','Admin test','admin');
set role authenticated;
select set_config('request.jwt.claim.sub','50000000-0000-0000-0000-000000000005',false);
select set_config('request.jwt.claim.role','authenticated',false);
update public.jobs set driver_paid=true where id='40000000-0000-0000-0000-000000000004' and status='completed' and driver_paid=false;
do $$
begin
  if not (select driver_paid from public.jobs where id='40000000-0000-0000-0000-000000000004') then
    raise exception 'admin payment update failed';
  end if;
  begin
    update public.jobs set price=777 where id='40000000-0000-0000-0000-000000000004';
    raise exception 'admin job detail modification unexpectedly succeeded';
  exception when others then
    if sqlerrm = 'admin job detail modification unexpectedly succeeded' then raise; end if;
  end;
end $$;
reset role;

-- Authenticated clients must not be able to INSERT notifications directly.
set role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000001',false);
select set_config('request.jwt.claim.role','authenticated',false);
do $$
begin
  begin
    insert into public.notifications(user_id,title,message) values(auth.uid(),'spoof','spoof');
    raise exception 'direct notification insert unexpectedly succeeded';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

select 'FLETYA security integration tests passed' as result;
