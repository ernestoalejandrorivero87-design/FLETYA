-- Disposable database only: creates synthetic Auth fixtures. Never run against hosted projects.
begin;
select set_config('request.jwt.claim.sub','',true);
select set_config('request.jwt.claim.role','service_role',true);
insert into auth.users(id,email,raw_user_meta_data) values
('91000000-0000-0000-0000-000000000001','pending@example.invalid','{"role":"driver","full_name":"Pending driver","phone":"9981234567","vehicle_type":"pickup","plates":"TEST-123","driver_status":"approved"}');
do $$ begin
 if (select driver_status from public.profiles where id='91000000-0000-0000-0000-000000000001')<>'pending' then raise exception 'Signup metadata bypassed approval';end if;
end $$;
insert into public.jobs(id,client_id,origin,destination,distance_km,vehicle_type,helpers,service_type,price)
 values('92000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','A','B',5,'pickup',0,'Mudanza',295);
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','91000000-0000-0000-0000-000000000001',true);
do $$ begin
 if exists(select 1 from public.jobs where id='92000000-0000-0000-0000-000000000002') then raise exception 'Pending driver read available jobs';end if;
 begin update public.profiles set driver_status='approved' where id=auth.uid();raise exception 'TESTFAIL self approval';exception when others then if sqlerrm='TESTFAIL self approval' then raise;end if;end;
 begin perform public.review_driver_application(auth.uid(),true,'Self approval attempt');raise exception 'TESTFAIL nonadmin review';exception when insufficient_privilege then null;end;
end $$;
select set_config('request.jwt.claim.sub','50000000-0000-0000-0000-000000000005',true);
select public.review_driver_application('91000000-0000-0000-0000-000000000001',true,'Synthetic valid pilot approval');
select set_config('request.jwt.claim.sub','91000000-0000-0000-0000-000000000001',true);
do $$ begin if not exists(select 1 from public.jobs where id='92000000-0000-0000-0000-000000000002') then raise exception 'Approved driver cannot see request';end if;end $$;
update public.jobs set status='en_route',driver_id=auth.uid() where id='92000000-0000-0000-0000-000000000002';
insert into public.job_arrivals(job_id,driver_id,stop) values('92000000-0000-0000-0000-000000000002',auth.uid(),'pickup') on conflict(job_id,driver_id,stop,assignment_cycle) do nothing;
insert into public.job_arrivals(job_id,driver_id,stop) values('92000000-0000-0000-0000-000000000002',auth.uid(),'pickup') on conflict(job_id,driver_id,stop,assignment_cycle) do nothing;
do $$ begin
 begin insert into public.job_arrivals(job_id,driver_id,stop) values('92000000-0000-0000-0000-000000000002',auth.uid(),'delivery');raise exception 'TESTFAIL premature delivery arrival';exception when insufficient_privilege then null;end;
end $$;
update public.jobs set status='picked_up' where id='92000000-0000-0000-0000-000000000002';
insert into public.job_arrivals(job_id,driver_id,stop) values('92000000-0000-0000-0000-000000000002',auth.uid(),'delivery');
update public.jobs set status='completed' where id='92000000-0000-0000-0000-000000000002';
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000001',true);
do $$ begin
 if (select count(*) from public.notifications where job_id='92000000-0000-0000-0000-000000000002' and type like 'client_%')<>6 then raise exception 'Missing or duplicate client transition events';end if;
 if (select count(*) from public.job_arrivals where job_id='92000000-0000-0000-0000-000000000002')<>2 then raise exception 'Arrival retries duplicated events';end if;
 begin perform public.authorize_push_hook('wrong');raise exception 'TESTFAIL public push authentication';exception when insufficient_privilege then null;end;
 begin insert into public.notifications(user_id,title,message,type) values(auth.uid(),'Spoof','Spoof','client_completed');raise exception 'TESTFAIL forged event';exception when insufficient_privilege then null;end;
end $$;
reset role;
do $$ begin
 if (select count(*) from private.client_push_outbox where job_id='92000000-0000-0000-0000-000000000002')<>6 then raise exception 'Missing client outbox events';end if;
 if (select count(*) from public.driver_application_reviews where driver_id='91000000-0000-0000-0000-000000000001')<>1 then raise exception 'Missing approval audit';end if;
end $$;
rollback;
