-- Rollback-only checks: use existing account roles, synthetic jobs and no Auth writes.
-- CI runs this after integration.sql. Hosted validation also rolls everything back.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '20s';
create temporary table cancellation_cases(label text primary key, id uuid default gen_random_uuid(), before_row jsonb) on commit drop;
insert into cancellation_cases(label) values
 ('own'),('other'),('assigned'),('active'),('picked_up'),('completed'),('paid'),('edit'),('cancel_first'),('accept_first');
select set_config('fletya.cancel_client', (select id::text from public.profiles where role='client' order by id limit 1), true);
select set_config('fletya.cancel_driver', (select id::text from public.profiles where role='driver' order by id limit 1), true);
select set_config('fletya.cancel_admin', (select id::text from public.profiles where role='admin' order by id limit 1), true);
do $$ begin
 if current_setting('fletya.cancel_client') = '' or current_setting('fletya.cancel_driver') = '' or current_setting('fletya.cancel_admin') = '' then
  raise exception 'Cancellation checks need client, driver and admin accounts';
 end if;
end $$;
select set_config('fletya.cancel_ids', (select jsonb_object_agg(label,id)::text from cancellation_cases), true);
select set_config('request.jwt.claim.role','service_role',true);
select set_config('request.jwt.claims','{"role":"service_role"}',true);
insert into public.jobs(id,origin,destination,distance_km,vehicle_type,helpers,service_type,description,price,status,client_id,driver_id,driver_paid)
select c.id,'Cancellation test origin','Cancellation test destination',5,'pickup',0,'Mudanza','Rollback-only cancellation validation',100,
 case c.label when 'active' then 'en_route' when 'picked_up' then 'picked_up' when 'completed' then 'completed' else 'requested' end,
 (case when c.label='other' then current_setting('fletya.cancel_admin') else current_setting('fletya.cancel_client') end)::uuid,
 case when c.label in ('assigned','active','picked_up','completed') then current_setting('fletya.cancel_driver')::uuid else null end,
 c.label='paid'
from cancellation_cases c;
update cancellation_cases c set before_row=to_jsonb(j) from public.jobs j where j.id=c.id;

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub',current_setting('fletya.cancel_client'),true);
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',current_setting('fletya.cancel_client'))::text,true);
do $$
declare ids jsonb:=current_setting('fletya.cancel_ids')::jsonb; n integer; label text; change_sql text; before_row jsonb; after_row jsonb;
begin
 select to_jsonb(j) into before_row from public.jobs j where id=(ids->>'own')::uuid;
 update public.jobs set status='cancelled' where id=(ids->>'own')::uuid and client_id=auth.uid() and status='requested' and driver_id is null;
 get diagnostics n=row_count;
 if n<>1 then raise exception 'Owning client cancellation failed'; end if;
 select to_jsonb(j) into after_row from public.jobs j where id=(ids->>'own')::uuid;
 if (before_row-'status') is distinct from (after_row-'status') then raise exception 'Cancellation changed other fields'; end if;
 update public.jobs set status='requested' where id=(ids->>'own')::uuid;
 get diagnostics n=row_count;
 if n<>0 then raise exception 'Cancelled job was reopened'; end if;
 foreach label in array array['other','assigned','active','picked_up','completed','paid'] loop
  update public.jobs set status='cancelled' where id=(ids->>label)::uuid;
  get diagnostics n=row_count;
  if n<>0 then raise exception 'Client cancelled forbidden case %',label; end if;
 end loop;
 foreach change_sql in array array['price=101','origin=''changed''','driver_paid=true',
  'client_id='''||current_setting('fletya.cancel_admin')||'''::uuid',
  'driver_id='''||current_setting('fletya.cancel_driver')||'''::uuid','updated_at=now()+interval ''1 second'''] loop
  begin
   execute 'update public.jobs set status=''cancelled'', '||change_sql||' where id=$1' using (ids->>'edit')::uuid;
   raise exception 'TESTFAIL: cancellation changed protected fields';
  exception when raise_exception then
   if sqlerrm not like 'Clients may only cancel their own unassigned unpaid requests%' then raise; end if;
  end;
 end loop;
 begin
  insert into public.jobs(origin,destination,price,status,client_id) values ('A','B',100,'cancelled',auth.uid());
  raise exception 'TESTFAIL: inserted a cancelled job';
 exception when raise_exception then
  if sqlerrm not like 'Clients may only create their own new, unassigned, unpaid requests%' then raise; end if;
 end;
 update public.jobs set status='cancelled' where id=(ids->>'cancel_first')::uuid;
 get diagnostics n=row_count;
 if n<>1 then raise exception 'Cancel-first transition failed'; end if;
end $$;

-- A cancelled request is invisible/unacceptable to the driver. Acceptance wins the other ordering.
select set_config('request.jwt.claim.sub',current_setting('fletya.cancel_driver'),true);
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',current_setting('fletya.cancel_driver'))::text,true);
do $$
declare ids jsonb:=current_setting('fletya.cancel_ids')::jsonb; n integer;
begin
 if exists(select 1 from public.jobs where id=(ids->>'cancel_first')::uuid) then raise exception 'Driver sees cancelled unassigned request'; end if;
 update public.jobs set status='en_route',driver_id=auth.uid() where id=(ids->>'cancel_first')::uuid and status='requested' and driver_id is null;
 get diagnostics n=row_count;
 if n<>0 then raise exception 'Driver accepted a cancelled request'; end if;
 update public.jobs set status='en_route',driver_id=auth.uid() where id=(ids->>'accept_first')::uuid and status='requested' and driver_id is null;
 get diagnostics n=row_count;
 if n<>1 then raise exception 'Accept-first transition failed'; end if;
 begin
  update public.jobs set status='cancelled' where id=(ids->>'active')::uuid;
  raise exception 'TESTFAIL: driver cancelled own active service';
 exception when raise_exception then
  if sqlerrm not like 'Drivers may only accept%' then raise; end if;
 end;
end $$;
select set_config('request.jwt.claim.sub',current_setting('fletya.cancel_client'),true);
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',current_setting('fletya.cancel_client'))::text,true);
do $$
declare n integer;
begin
 update public.jobs set status='cancelled' where id=(current_setting('fletya.cancel_ids')::jsonb->>'accept_first')::uuid;
 get diagnostics n=row_count;
 if n<>0 then raise exception 'Client cancelled after driver acceptance'; end if;
end $$;

-- Admin payment protections still apply; this feature does not add admin cancellation.
select set_config('request.jwt.claim.sub',current_setting('fletya.cancel_admin'),true);
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',current_setting('fletya.cancel_admin'))::text,true);
do $$
begin
 begin
  update public.jobs set driver_paid=true where id=(current_setting('fletya.cancel_ids')::jsonb->>'own')::uuid;
  raise exception 'TESTFAIL: admin paid a cancelled request';
 exception when raise_exception then
  if sqlerrm not like 'Only unpaid completed jobs can be marked as paid%' then raise; end if;
 end;
 begin
  update public.jobs set status='cancelled' where id=(current_setting('fletya.cancel_ids')::jsonb->>'edit')::uuid;
  raise exception 'TESTFAIL: admin cancelled a request';
 exception when raise_exception then
  if sqlerrm not like 'Administrators may only change the payment flag%' then raise; end if;
 end;
end $$;
reset role;
do $$
begin
 if exists(select 1 from cancellation_cases c join public.jobs j on j.id=c.id
  where c.label not in ('own','cancel_first','accept_first') and to_jsonb(j) is distinct from c.before_row) then
  raise exception 'Unrelated fixture jobs were modified';
 end if;
end $$;
select 'FLETYA client cancellation checks passed; all synthetic changes rolled back' as result;
rollback;
