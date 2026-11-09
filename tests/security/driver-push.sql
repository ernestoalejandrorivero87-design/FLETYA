-- Rollback-only role/device tests, with existing identities and no Auth writes.
begin;
set local lock_timeout='3s';
set local statement_timeout='20s';
select set_config('push.driver',(select id::text from public.profiles where role='driver' order by id limit 1),true);
select set_config('push.client',(select id::text from public.profiles where role='client' order by id limit 1),true);
select set_config('push.installation',gen_random_uuid()::text,true);
select set_config('push.session',gen_random_uuid()::text,true);
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub',current_setting('push.driver'),true);
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',current_setting('push.driver'),'session_id',current_setting('push.session'))::text,true);
insert into public.driver_push_devices(user_id,installation_id,registration_nonce,token,enabled)
 values(auth.uid(),current_setting('push.installation')::uuid,gen_random_uuid(),'synthetic-fcm-token-not-real',true);
-- Match the PostgREST upsert contract, including primary key columns in update.
insert into public.driver_push_devices(user_id,installation_id,registration_nonce,token,enabled)
 values(auth.uid(),current_setting('push.installation')::uuid,gen_random_uuid(),'synthetic-rotated-fcm-token',true)
 on conflict(user_id,installation_id) do update set user_id=excluded.user_id,installation_id=excluded.installation_id,
 registration_nonce=excluded.registration_nonce,token=excluded.token,enabled=excluded.enabled;
do $$ begin
 if not exists(select 1 from public.driver_push_devices where user_id=auth.uid() and session_id=current_setting('push.session')::uuid) then raise exception 'Push session not server-derived'; end if;
 begin
  update public.driver_push_devices set session_id=gen_random_uuid() where user_id=auth.uid();
  raise exception 'TESTFAIL client overwrote session claim';
 exception when insufficient_privilege then null;end;
 begin
  perform public.claim_driver_push_batch(repeat('a',64));
  raise exception 'TESTFAIL authenticated can claim queue';
 exception when insufficient_privilege then null;end;
 begin
  perform public.finish_driver_push(gen_random_uuid(),1,'sent');
  raise exception 'TESTFAIL authenticated can finish queue';
 exception when insufficient_privilege then null;end;
 begin
  perform private.wake_driver_push();
  raise exception 'TESTFAIL authenticated can wake dispatcher';
 exception when insufficient_privilege then null;end;
end $$;
select set_config('request.jwt.claim.sub',current_setting('push.client'),true);
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',current_setting('push.client'),'session_id',current_setting('push.session'))::text,true);
do $$ begin
 if exists(select 1 from public.driver_push_devices) then raise exception 'Client read driver devices';end if;
 begin
  insert into public.driver_push_devices(user_id,installation_id,registration_nonce,token)
  values(auth.uid(),gen_random_uuid(),gen_random_uuid(),'synthetic-client-fcm-token');
  raise exception 'TESTFAIL client registered driver push';
 exception when insufficient_privilege then null;end;
end $$;
reset role;
set local role anon;
do $$ begin
 begin
  perform * from public.driver_push_devices;
  raise exception 'TESTFAIL anonymous reads tokens';
 exception when insufficient_privilege then null;end;
 begin
  perform public.claim_driver_push_batch(repeat('a',64));
  raise exception 'TESTFAIL anonymous invokes worker';
 exception when insufficient_privilege then null;end;
end $$;
reset role;
set local role service_role;
do $$ begin
 begin
  perform public.claim_driver_push_batch('wrong-secret');
  raise exception 'TESTFAIL worker accepts bad secret';
 exception when insufficient_privilege then null;end;
end $$;
reset role;
-- New notification queues exactly once without sending anything while disabled.
select set_config('request.jwt.claim.role','service_role',true);
select set_config('push.job',gen_random_uuid()::text,true);
insert into public.jobs(id,origin,destination,status,client_id) values(current_setting('push.job')::uuid,'Push test A','Push test B','requested',current_setting('push.client')::uuid);
insert into public.notifications(user_id,title,message,type,job_id) values(current_setting('push.driver')::uuid,'Push test','Synthetic notification','info',current_setting('push.job')::uuid);
do $$ begin
 if not exists(select 1 from private.driver_push_outbox where job_id=current_setting('push.job')::uuid and user_id=current_setting('push.driver')::uuid) then raise exception 'New request did not queue push';end if;
 if exists(select 1 from private.driver_push_config where enabled) then raise exception 'Migration activated delivery before server configuration';end if;
end $$;
rollback;
