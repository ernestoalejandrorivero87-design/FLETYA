-- Disposable only: synthetic Auth session. No real FCM token or network delivery.
begin;
select set_config('request.jwt.claim.sub','',true);select set_config('request.jwt.claim.role','service_role',true);
delete from private.client_push_outbox;
update private.driver_push_config set enabled=true,secret_hash=encode(sha256(convert_to(repeat('c',64),'UTF8')),'hex') where id;
insert into auth.sessions(id,user_id)values('93000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001');
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000001',true);
select set_config('request.jwt.claims','{"session_id":"93000000-0000-0000-0000-000000000003"}',true);
insert into public.client_push_devices(user_id,installation_id,registration_nonce,token)values(auth.uid(),'94000000-0000-0000-0000-000000000004','95000000-0000-0000-0000-000000000005','synthetic-client-device-token');
reset role;select set_config('request.jwt.claim.sub','',true);select set_config('request.jwt.claim.role','service_role',true);
insert into public.jobs(id,client_id,origin,destination,price,status)values('96000000-0000-0000-0000-000000000006','10000000-0000-0000-0000-000000000001','A','B',295,'requested');
update public.jobs set driver_id='20000000-0000-0000-0000-000000000002',status='en_route' where id='96000000-0000-0000-0000-000000000006';
set local role service_role;
do $$declare batch jsonb; item jsonb;begin
 batch:=public.claim_client_push_batch(repeat('c',64));
 if jsonb_array_length(batch)<>2 then raise exception 'Expected two client transition events';end if;
 for item in select value from jsonb_array_elements(batch)loop
  if jsonb_array_length(item->'devices')<>(case when item->>'event_type'='client_assigned' then 1 else 0 end) then raise exception 'Old push not superseded or active device missing';end if;
  perform public.finish_client_push((item->>'notification_id')::uuid,(item->>'attempt')::int,case when item->>'event_type'='client_assigned' then 'sent' else 'skipped' end);
 end loop;
end $$;
reset role;
delete from auth.sessions where id='93000000-0000-0000-0000-000000000003';
update public.jobs set status='picked_up' where id='96000000-0000-0000-0000-000000000006';
set local role service_role;
do $$declare batch jsonb;begin
 batch:=public.claim_client_push_batch(repeat('c',64));
 if jsonb_array_length(batch)<>1 or jsonb_array_length(batch->0->'devices')<>0 then raise exception 'Logged-out client session received push';end if;
end $$;
reset role;
rollback;
