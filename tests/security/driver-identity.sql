-- Rollback-only: existing role identities, no Auth writes.
begin;
set local lock_timeout='3s';
set local statement_timeout='20s';
select set_config('identity.client',(select id::text from public.profiles where role='client' order by id limit 1),true);
select set_config('identity.driver',(select id::text from public.profiles where role='driver' order by id limit 1),true);
select set_config('identity.other',(select id::text from public.profiles where role='admin' order by id limit 1),true);
select set_config('identity.job',gen_random_uuid()::text,true);
select set_config('request.jwt.claim.role','service_role',true);
select set_config('request.jwt.claims','{"role":"service_role"}',true);
insert into public.jobs(id,origin,destination,price,status,client_id,driver_id)
values(current_setting('identity.job')::uuid,'Identity test A','Identity test B',100,'en_route',current_setting('identity.client')::uuid,current_setting('identity.driver')::uuid);
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub',current_setting('identity.driver'),true);
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',current_setting('identity.driver'))::text,true);
do $$ declare n integer; begin
 update public.profiles set vehicle_type='camioneta',plates='TEST-123' where id=auth.uid();
 get diagnostics n=row_count;if n<>1 then raise exception 'Own driver vehicle did not save';end if;
 update public.profiles set vehicle_type='pickup' where id=current_setting('identity.other')::uuid;
 get diagnostics n=row_count;if n<>0 then raise exception 'Driver edited another profile';end if;
 begin
  update public.profiles set vehicle_type='spaceship' where id=auth.uid();
  raise exception 'TESTFAIL invalid vehicle saved';
 exception when check_violation then null;end;
 begin
  update public.profiles set plates='<script>' where id=auth.uid();
  raise exception 'TESTFAIL invalid plates saved';
 exception when check_violation then null;end;
 if exists(select 1 from public.get_assigned_driver(current_setting('identity.job')::uuid))then raise exception 'Driver called client identity RPC';end if;
end $$;
select set_config('request.jwt.claim.sub',current_setting('identity.client'),true);
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',current_setting('identity.client'))::text,true);
do $$ declare rowdata jsonb; begin
 select to_jsonb(d) into rowdata from public.get_assigned_driver(current_setting('identity.job')::uuid) d;
 if rowdata->>'driver_id' is distinct from current_setting('identity.driver') or rowdata->>'plates' is distinct from 'TEST-123' or rowdata->>'vehicle_type' is distinct from 'camioneta' then raise exception 'Client identity incorrect';end if;
 if rowdata ? 'email' or rowdata ? 'phone' or (select count(*) from jsonb_object_keys(rowdata))<>4 then raise exception 'Identity contains private fields';end if;
 if exists(select 1 from public.profiles where id=current_setting('identity.driver')::uuid) then raise exception 'Client gained direct profile access';end if;
 begin
  update public.profiles set plates='TEST-123' where id=auth.uid();
  raise exception 'TESTFAIL client vehicle edit accepted';
 exception when check_violation then null;end;
end $$;
reset role;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('request.jwt.claims','{"role":"service_role"}',true);
update public.jobs set status='picked_up' where id=current_setting('identity.job')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',current_setting('identity.client'))::text,true);
do $$ begin
 if not exists(select 1 from public.get_assigned_driver(current_setting('identity.job')::uuid)) then raise exception 'Picked-up job lost driver identity';end if;
end $$;
reset role;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('request.jwt.claims','{"role":"service_role"}',true);
update public.jobs set status='completed' where id=current_setting('identity.job')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',current_setting('identity.client'))::text,true);
do $$ begin
 if exists(select 1 from public.get_assigned_driver(current_setting('identity.job')::uuid)) then raise exception 'Completed job exposes active identity';end if;
end $$;
reset role;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('request.jwt.claims','{"role":"service_role"}',true);
update public.jobs set status='en_route' where id=current_setting('identity.job')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub',current_setting('identity.other'),true);
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',current_setting('identity.other'))::text,true);
do $$ begin
 if exists(select 1 from public.get_assigned_driver(current_setting('identity.job')::uuid))then raise exception 'Nonowner sees identity';end if;
end $$;
reset role;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('request.jwt.claims','{"role":"service_role"}',true);
update public.jobs set status='requested',driver_id=null,release_reason='Identity test release' where id=current_setting('identity.job')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub',current_setting('identity.client'),true);
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',current_setting('identity.client'))::text,true);
do $$ begin
 if exists(select 1 from public.get_assigned_driver(current_setting('identity.job')::uuid)) then raise exception 'Released job retains identity';end if;
end $$;
reset role;
-- Trusted fixture swaps assignment to the owning client identity; non-driver profiles must never be exposed.
select set_config('request.jwt.claim.role','service_role',true);
select set_config('request.jwt.claims','{"role":"service_role"}',true);
update public.jobs set status='en_route',driver_id=current_setting('identity.client')::uuid where id=current_setting('identity.job')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub',current_setting('identity.client'),true);
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',current_setting('identity.client'))::text,true);
do $$ begin
 if exists(select 1 from public.get_assigned_driver(current_setting('identity.job')::uuid)) then raise exception 'Non-driver profile exposed';end if;
end $$;
reset role;
do $$ begin
 if has_function_privilege('anon','public.get_assigned_driver(uuid)','EXECUTE') then raise exception 'Anonymous identity RPC execution';end if;
end $$;
select 'Driver identity permissions passed; changes rolled back' as result;
rollback;
