-- Existing drivers retain pilot access; new signups require an administrator review.
alter table public.profiles add column driver_status text not null default 'approved'
 check(driver_status in ('pending','approved','rejected'));
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path='' as $$
declare driver boolean := new.raw_user_meta_data->>'role'='driver'; vehicle text := new.raw_user_meta_data->>'vehicle_type'; plate text := upper(trim(new.raw_user_meta_data->>'plates'));
begin
 insert into public.profiles(id,full_name,phone,role,email,vehicle_type,plates,driver_status)
 values(new.id,left(trim(new.raw_user_meta_data->>'full_name'),100),left(trim(new.raw_user_meta_data->>'phone'),20),
 case when driver then 'driver' else 'client' end,new.email,
 case when driver and vehicle in ('pickup','camioneta','camion') then vehicle else null end,
 case when driver and plate ~ '^[A-Z0-9 -]{3,15}$' then plate else null end,
 case when driver then 'pending' else 'approved' end);
 return new;
end $$;
create or replace function public.guard_profile_role_changes() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='INSERT' then
  if pg_trigger_depth()=1 and auth.uid() is not null and not private.is_admin() then raise exception 'Profiles are created by the sign-up process';end if;
 elsif (new.role is distinct from old.role or new.driver_status is distinct from old.driver_status)
   and auth.uid() is not null and not private.is_admin() then raise exception 'Only administrators may review driver access or change roles';
 end if;
 return new;
end $$;
drop trigger guard_profile_role_changes on public.profiles;
create trigger guard_profile_role_changes before insert or update of role,driver_status on public.profiles for each row execute function public.guard_profile_role_changes();
create function private.driver_access_allowed() returns boolean language sql stable security invoker set search_path='' as $$
 select not exists(select 1 from public.profiles where id=(select auth.uid()) and role='driver' and driver_status<>'approved');
$$;
revoke all on function private.driver_access_allowed() from public,anon;
grant execute on function private.driver_access_allowed() to authenticated;
-- Restrictive policies intersect every existing permissive policy, including older app versions.
create policy approved_driver_access on public.jobs as restrictive to authenticated using(private.driver_access_allowed()) with check(private.driver_access_allowed());
create policy approved_driver_location on public.driver_locations as restrictive to authenticated using(private.driver_access_allowed()) with check(private.driver_access_allowed());
create policy approved_driver_notices on public.notifications as restrictive to authenticated using(private.driver_access_allowed()) with check(private.driver_access_allowed());
create policy approved_driver_push on public.driver_push_devices as restrictive to authenticated using(private.driver_access_allowed()) with check(private.driver_access_allowed());
create table public.driver_application_reviews(
 id uuid primary key default gen_random_uuid(),driver_id uuid not null references public.profiles(id),
 reviewed_by uuid not null references public.profiles(id),approved boolean not null,note text not null check(length(note) between 10 and 500),
 reviewed_at timestamptz not null default clock_timestamp()
);
alter table public.driver_application_reviews enable row level security;
revoke all on public.driver_application_reviews from public,anon,authenticated;
grant select on public.driver_application_reviews to authenticated;
create policy own_driver_review on public.driver_application_reviews for select to authenticated using(driver_id=(select auth.uid()) or private.is_admin());
create function public.review_driver_application(p_driver_id uuid,p_approved boolean,p_note text) returns jsonb
 language plpgsql security definer set search_path='' as $$
declare reviewed public.profiles;
begin
 if auth.uid() is null or not private.is_admin() then raise insufficient_privilege using message='Administrator required';end if;
 if p_approved is null or p_note is null or length(trim(p_note)) not between 10 and 500 then raise exception 'Review note required';end if;
 select * into reviewed from public.profiles where id=p_driver_id and role='driver' and driver_status='pending' for update;
 if not found then raise exception 'Application is no longer pending';end if;
 if p_approved and (nullif(trim(reviewed.full_name),'') is null or reviewed.vehicle_type not in ('pickup','camioneta','camion')
  or reviewed.vehicle_type is null or coalesce(reviewed.plates,'') !~ '^[A-Z0-9 -]{3,15}$' or coalesce(reviewed.phone,'') !~ '^\+?[0-9]{10,15}$') then raise exception 'Complete driver name, phone, vehicle and plates before approval';end if;
 update public.profiles set driver_status=case when p_approved then 'approved' else 'rejected' end where id=p_driver_id;
 insert into public.driver_application_reviews(driver_id,reviewed_by,approved,note) values(p_driver_id,auth.uid(),p_approved,trim(p_note));
 return jsonb_build_object('driver_id',p_driver_id,'status',case when p_approved then 'approved' else 'rejected' end);
end $$;
revoke all on function public.review_driver_application(uuid,boolean,text) from public,anon;
grant execute on function public.review_driver_application(uuid,boolean,text) to authenticated;

-- Authoritative service events are emitted by database transitions, never by a public notification INSERT.
create function private.client_service_event(p_job uuid,p_user uuid,p_event text) returns void language plpgsql security definer set search_path='' as $$
declare heading text;
begin
 heading:=case p_event when 'client_requested' then 'Solicitud registrada' when 'client_assigned' then 'Fletero asignado'
  when 'client_arrived_pickup' then 'El fletero llegó a recogida' when 'client_picked_up' then 'Carga recogida'
  when 'client_arrived_delivery' then 'El fletero llegó a entrega' when 'client_completed' then 'Servicio completado'
  when 'client_cancelled' then 'Solicitud cancelada' when 'client_released' then 'Buscando otro fletero' end;
 if heading is null then raise exception 'Invalid service event';end if;
 insert into public.notifications(user_id,job_id,title,message,type) values(p_user,p_job,heading,'Abre FLETYA para consultar el estado del servicio.',p_event);
end $$;
revoke all on function private.client_service_event(uuid,uuid,text) from public,anon,authenticated;
create function private.notify_client_job_change() returns trigger language plpgsql security definer set search_path='' as $$
declare event text;
begin
 if tg_op='INSERT' then event:='client_requested';
 elsif new.status is not distinct from old.status then return new;
 elsif new.status='en_route' then event:='client_assigned';
 elsif new.status='picked_up' then event:='client_picked_up';
 elsif new.status='completed' then event:='client_completed';
 elsif new.status='cancelled' then event:='client_cancelled';
 elsif new.status='requested' and old.status='en_route' and old.driver_id is not null and new.driver_id is null then event:='client_released';
 else return new;end if;
 perform private.client_service_event(new.id,new.client_id,event);return new;
end $$;
revoke all on function private.notify_client_job_change() from public,anon,authenticated;
create trigger notify_client_job_change after insert or update of status on public.jobs for each row execute function private.notify_client_job_change();
create table public.job_arrivals(
 job_id uuid not null references public.jobs(id) on delete cascade,driver_id uuid not null references public.profiles(id),
 stop text not null check(stop in ('pickup','delivery')),arrived_at timestamptz not null default clock_timestamp(),
 assignment_cycle bigint not null default 0,
 primary key(job_id,driver_id,stop,assignment_cycle)
);
alter table public.job_arrivals enable row level security;
revoke all on public.job_arrivals from public,anon,authenticated;
grant select on public.job_arrivals to authenticated;
grant insert(job_id,driver_id,stop) on public.job_arrivals to authenticated;
create policy arrival_participants on public.job_arrivals for select to authenticated using(driver_id=(select auth.uid()) or exists(select 1 from public.jobs where id=job_id and client_id=(select auth.uid())) or private.is_admin());
create policy driver_marks_arrival on public.job_arrivals for insert to authenticated with check(driver_id=(select auth.uid()) and private.driver_access_allowed()
 and exists(select 1 from public.profiles where id=(select auth.uid()) and role='driver')
 and exists(select 1 from public.jobs where id=job_id and driver_id=(select auth.uid()) and ((stop='pickup' and status='en_route') or (stop='delivery' and status='picked_up'))));
create function private.validate_arrival() returns trigger language plpgsql security definer set search_path='' as $$
declare job public.jobs;
begin
 select * into job from public.jobs where id=new.job_id for update;
 if not found or job.driver_id is distinct from auth.uid() or new.driver_id is distinct from auth.uid()
  or not ((new.stop='pickup' and job.status='en_route') or (new.stop='delivery' and job.status='picked_up')) then
  raise insufficient_privilege using message='Arrival requires the current driver and service phase';end if;
 new.arrived_at:=clock_timestamp();
 select count(*) into new.assignment_cycle from public.job_driver_releases where job_id=new.job_id;
 return new;
end $$;
revoke all on function private.validate_arrival() from public,anon,authenticated;
create trigger validate_arrival before insert on public.job_arrivals for each row execute function private.validate_arrival();
create function private.notify_client_arrival() returns trigger language plpgsql security definer set search_path='' as $$
declare owner_id uuid;
begin
 select client_id into owner_id from public.jobs where id=new.job_id;
 perform private.client_service_event(new.job_id,owner_id,case when new.stop='pickup' then 'client_arrived_pickup' else 'client_arrived_delivery' end);return new;
end $$;
revoke all on function private.notify_client_arrival() from public,anon,authenticated;
create trigger notify_client_arrival after insert on public.job_arrivals for each row execute function private.notify_client_arrival();
notify pgrst,'reload schema';
