-- Disposable fixture ONLY: inserts synthetic Auth sessions. Never run on a hosted project.
begin;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('worker.driver',(select id::text from public.profiles where role='driver' order by id limit 1),true);
select set_config('worker.client',(select id::text from public.profiles where role='client' order by id limit 1),true);
select set_config('worker.session',gen_random_uuid()::text,true);
select set_config('worker.device',gen_random_uuid()::text,true);
select set_config('worker.nonce',gen_random_uuid()::text,true);
select set_config('worker.job',gen_random_uuid()::text,true);
select set_config('worker.notification',gen_random_uuid()::text,true);
insert into auth.sessions(id,user_id) values(current_setting('worker.session')::uuid,current_setting('worker.driver')::uuid);
update private.driver_push_config set enabled=true,secret_hash=encode(sha256(convert_to(repeat('a',64),'UTF8')),'hex');
select set_config('request.jwt.claim.sub',current_setting('worker.driver'),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('worker.driver'),'session_id',current_setting('worker.session'))::text,true);
set local role authenticated;
insert into public.driver_push_devices(user_id,installation_id,registration_nonce,token)
 values(auth.uid(),current_setting('worker.device')::uuid,current_setting('worker.nonce')::uuid,'synthetic-worker-token-original');
reset role;
-- Remove only disposable fixture work that could make this driver busy.
update public.jobs set status='completed' where driver_id=current_setting('worker.driver')::uuid and status in ('en_route','picked_up');
insert into public.jobs(id,origin,destination,status,client_id) values(current_setting('worker.job')::uuid,'Worker A','Worker B','requested',current_setting('worker.client')::uuid);
insert into public.notifications(id,user_id,title,message,type,job_id) values(current_setting('worker.notification')::uuid,current_setting('worker.driver')::uuid,'Synthetic','Synthetic','info',current_setting('worker.job')::uuid);
set local role service_role;
do $$ declare batch jsonb; begin
 batch:=public.claim_driver_push_batch(repeat('a',64));
 if not exists(select 1 from jsonb_array_elements(batch) e where e->>'notification_id'=current_setting('worker.notification') and jsonb_array_length(e->'devices')=1) then
  raise exception 'Eligible signed-in driver device missing from queue';
 end if;
end $$;
reset role;
-- Rotate a token after claim: the response for the old token must not disable the new one.
set local role authenticated;
update public.driver_push_devices set token='synthetic-worker-token-rotated' where user_id=auth.uid();
reset role;
set local role service_role;
select public.finish_driver_push(current_setting('worker.notification')::uuid,1,'retry',jsonb_build_array(jsonb_build_object('installation_id',current_setting('worker.device'),'registration_nonce',current_setting('worker.nonce'),'token','synthetic-worker-token-original')));
do $$ begin
 if not exists(select 1 from public.driver_push_devices where installation_id=current_setting('worker.device')::uuid and enabled) then raise exception 'Token rotation disabled valid device';end if;
end $$;
reset role;
-- Logout: no device from a removed Auth session may be targeted.
delete from auth.sessions where id=current_setting('worker.session')::uuid;
update private.driver_push_outbox set available_at=now(),locked_until=null where notification_id=current_setting('worker.notification')::uuid;
set local role service_role;
do $$ declare batch jsonb; begin
 batch:=public.claim_driver_push_batch(repeat('a',64));
 if exists(select 1 from jsonb_array_elements(batch) e where jsonb_array_length(e->'devices')>0) then raise exception 'Logged-out session was targeted';end if;
end $$;
reset role;
rollback;
