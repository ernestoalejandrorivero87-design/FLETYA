-- FLETYA-testing only: ccdtpwvalqznasstnqxj. Never run on production.
-- Review the exact identity allowlist and counts before executing.
begin;
create temporary table cleanup_users (id uuid primary key, email text not null) on commit drop;
insert into cleanup_users values
 ('c82f84a9-0adf-4c89-9639-c3bbf2436e5f','api-permissions-971b263989a44bd9a0c08cc47884d58a@example.com'),
 ('e599bb7a-ddc5-4e01-a13b-b059f218af1a','api-permissions-aa23d1a4fe9a46c7bc1be0a13d2753d4@example.com'),
 ('d7689973-8592-430a-a668-57511fa07991','api-permissions-5bd5471d3f824168b647f74f53863a92@example.com'),
 ('d281f7a4-4fb7-488b-9825-1155b641d2e6','api-permissions-fb8107dbc3cb458580e8ddacaaf597fd@example.com'),
 ('487e7dec-ea89-4969-83e4-459b9331645c','fletya-http-cliente-a@example.com'),
 ('271b51f1-affd-4ffd-9247-114e65917ff8','fletya-http-cliente-b@example.com'),
 ('6b42a407-93ef-42e3-a0a9-e2b096a0ded2','fletya-http-fletero-a@example.com'),
 ('fa8c0e2e-5477-493c-9740-03f3a3c1b139','fletya-http-fletero-b@example.com');
do $$ begin
 if (select count(*) from auth.users u join cleanup_users c on u.id=c.id and u.email=c.email) <> 8 then
   raise exception 'Cleanup allowlist does not match all eight disposable identities';
 end if;
 if exists(select 1 from public.jobs where driver_id in (select id from cleanup_users)
   and (client_id is null or client_id not in (select id from cleanup_users))) then
   raise exception 'A non-fixture client references a disposable driver; stop';
 end if;
end $$;
create temporary table cleanup_jobs on commit drop as
 select id from public.jobs where client_id in (select id from cleanup_users);
do $$ begin
 if (select count(*) from cleanup_jobs) <> 5 then
   raise exception 'Expected exactly five disposable services; stop';
 end if;
end $$;
-- Preserve every non-fixture application row for an in-transaction comparison.
create temporary table cleanup_survivors (kind text, id uuid, row_data jsonb) on commit drop;
insert into cleanup_survivors
 select 'profiles',id,to_jsonb(p) from public.profiles p where id not in (select id from cleanup_users)
 union all select 'jobs',id,to_jsonb(j) from public.jobs j where id not in (select id from cleanup_jobs)
 union all select 'notifications',id,to_jsonb(n) from public.notifications n
   where user_id not in (select id from cleanup_users)
   and (job_id is null or job_id not in (select id from cleanup_jobs))
 union all select 'gps',id,to_jsonb(g) from public.driver_locations g
   where driver_id not in (select id from cleanup_users)
   and (job_id is null or job_id not in (select id from cleanup_jobs));
-- Revoke refresh sessions first. Existing access JWTs expire normally; deleting
-- all owned application rows and profiles removes their application access.
delete from auth.sessions where user_id in (select id from cleanup_users);
delete from public.notifications where user_id in (select id from cleanup_users)
 or job_id in (select id from cleanup_jobs);
delete from public.driver_locations where driver_id in (select id from cleanup_users)
 or job_id in (select id from cleanup_jobs);
delete from public.jobs where id in (select id from cleanup_jobs);
delete from auth.users u using cleanup_users c where u.id=c.id and u.email=c.email;
do $$ begin
 if exists(select 1 from auth.users where id in (select id from cleanup_users)) then
   raise exception 'Disposable users remain';
 end if;
 if exists(select 1 from public.profiles where id in (select id from cleanup_users)) then
   raise exception 'Disposable profiles remain';
 end if;
 if exists(
   select kind,id,row_data from cleanup_survivors
   except
   (select 'profiles',id,to_jsonb(p) from public.profiles p
    union all select 'jobs',id,to_jsonb(j) from public.jobs j
    union all select 'notifications',id,to_jsonb(n) from public.notifications n
    union all select 'gps',id,to_jsonb(g) from public.driver_locations g)
 ) then raise exception 'Non-fixture application data changed; rolling back'; end if;
end $$;
drop function if exists public.fletya_session_permission_probe();
commit;
select jsonb_build_object(
 'users',(select count(*) from auth.users),
 'profiles',(select count(*) from public.profiles),
 'jobs',(select count(*) from public.jobs),
 'notifications',(select count(*) from public.notifications),
 'gps',(select count(*) from public.driver_locations),
 'diagnostic_rpc_removed',to_regprocedure('public.fletya_session_permission_probe()') is null
) as cleanup_result;
