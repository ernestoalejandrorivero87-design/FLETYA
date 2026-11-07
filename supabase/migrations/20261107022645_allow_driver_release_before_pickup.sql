-- Pickup and reasoned release before loading. Existing rows retain their values.
do $migration$
declare jobs_before text;
begin
 perform set_config('lock_timeout','5s',true);
 lock table public.jobs in share row exclusive mode;
 select md5(coalesce(string_agg((to_jsonb(j)-'release_reason')::text,'' order by id),'')) into jobs_before from public.jobs j;
 execute $ddl$
alter table public.jobs add column if not exists release_reason text;
alter table public.jobs drop constraint if exists jobs_status_check;
alter table public.jobs add constraint jobs_status_check
 check (status in ('requested','accepted','en_route','picked_up','completed','cancelled'));

CREATE OR REPLACE FUNCTION public.guard_job_updates()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  actor_role text;
  is_service_role boolean := coalesce(auth.role(), '') = 'service_role';
begin
  if is_service_role then
    return new;
  end if;

  if auth.uid() is null then
    raise exception 'A signed-in user is required to modify a job';
  end if;

  select p.role into actor_role
  from public.profiles p
  where p.id = auth.uid();

  if tg_op = 'INSERT' then
    if actor_role is distinct from 'client'
      or new.client_id is distinct from auth.uid()
      or new.status is distinct from 'requested'
      or new.driver_id is not null
      or new.release_reason is not null
      or coalesce(new.driver_paid, false) <> false then
      raise exception 'Clients may only create their own new, unassigned, unpaid requests';
    end if;
    new.driver_paid := false;
    return new;
  end if;

  -- Only the owning client may cancel an available, unpaid request.
  -- Comparing the complete row also protects future columns.
  if actor_role = 'client' then
    if old.client_id is distinct from auth.uid()
      or old.status is distinct from 'requested'
      or old.driver_id is not null
      or coalesce(old.driver_paid, false) <> false
      or new.status is distinct from 'cancelled'
      or (to_jsonb(new) - 'status') is distinct from (to_jsonb(old) - 'status') then
      raise exception 'Clients may only cancel their own unassigned unpaid requests without other changes';
    end if;
    return new;
  end if;

  if actor_role = 'admin' and private.is_admin() then
    if new.id is distinct from old.id
      or new.origin is distinct from old.origin
      or new.destination is distinct from old.destination
      or new.distance_km is distinct from old.distance_km
      or new.vehicle_type is distinct from old.vehicle_type
      or new.helpers is distinct from old.helpers
      or new.service_type is distinct from old.service_type
      or new.description is distinct from old.description
      or new.price is distinct from old.price
      or new.status is distinct from old.status
      or new.client_id is distinct from old.client_id
      or new.driver_id is distinct from old.driver_id
      or new.created_at is distinct from old.created_at
      or new.updated_at is distinct from old.updated_at
      or new.release_reason is distinct from old.release_reason then
      raise exception 'Administrators may only change the payment flag through this app';
    end if;

    if new.driver_paid is distinct from old.driver_paid
       and not (old.status = 'completed' and coalesce(old.driver_paid, false) = false and new.driver_paid = true) then
      raise exception 'Only unpaid completed jobs can be marked as paid';
    end if;
    return new;
  end if;

  if actor_role = 'driver' then
    if (to_jsonb(new) - array['status','driver_id','release_reason'])
       is distinct from (to_jsonb(old) - array['status','driver_id','release_reason']) then
      raise exception 'Drivers cannot edit job details or payment flags';
    end if;
    if old.status = 'requested' and old.driver_id is null
      and new.status = 'en_route' and new.driver_id = auth.uid()
      and new.release_reason is not distinct from old.release_reason then
      return new;
    end if;
    if old.driver_id = auth.uid() and new.driver_id = old.driver_id
      and new.release_reason is not distinct from old.release_reason
      and ((old.status = 'en_route' and new.status = 'picked_up')
        or (old.status = 'picked_up' and new.status = 'completed')) then
      return new;
    end if;
    if old.driver_id = auth.uid() and old.status = 'en_route'
      and coalesce(old.driver_paid,false) = false
      and new.status = 'requested' and new.driver_id is null
      and char_length(btrim(coalesce(new.release_reason,''))) between 10 and 300 then
      new.release_reason := btrim(new.release_reason);
      return new;
    end if;
    raise exception 'Drivers may only accept requests, confirm pickup, complete picked-up cargo or release before pickup with a reason';
  end if;

  raise exception 'This account is not authorized to update jobs';
end;
$function$
;
revoke all on function public.guard_job_updates() from public, anon, authenticated;

drop policy if exists "Drivers can complete their jobs" on public.jobs;
create policy "Drivers can complete their jobs" on public.jobs for update to authenticated
 using (status='picked_up' and driver_id=(select auth.uid()) and exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.role='driver'))
 with check (status='completed' and driver_id=(select auth.uid()) and exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.role='driver'));
create policy "Drivers can confirm cargo pickup" on public.jobs for update to authenticated
 using (status='en_route' and driver_id=(select auth.uid()) and exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.role='driver'))
 with check (status='picked_up' and driver_id=(select auth.uid()) and exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.role='driver'));
create policy "Drivers can release before pickup" on public.jobs for update to authenticated
 using (status='en_route' and driver_id=(select auth.uid()) and coalesce(driver_paid,false)=false and exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.role='driver'))
 with check (status='requested' and driver_id is null and coalesce(driver_paid,false)=false and exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.role='driver'));

drop policy if exists driver_insert_location on public.driver_locations;
create policy driver_insert_location on public.driver_locations for insert to authenticated
 with check (driver_id=(select auth.uid()) and exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.role='driver')
 and exists(select 1 from public.jobs j where j.id=job_id and j.driver_id=(select auth.uid()) and j.status in ('en_route','picked_up')));
drop policy if exists driver_update_location on public.driver_locations;
create policy driver_update_location on public.driver_locations for update to authenticated
 using (driver_id=(select auth.uid()) and exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.role='driver'))
 with check (driver_id=(select auth.uid()) and exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.role='driver')
 and exists(select 1 from public.jobs j where j.id=job_id and j.driver_id=(select auth.uid()) and j.status in ('en_route','picked_up')));
drop policy if exists view_job_driver_location on public.driver_locations;
create policy view_job_driver_location on public.driver_locations for select to authenticated
 using (driver_id=(select auth.uid()) or exists(select 1 from public.jobs j
 where j.id=job_id and j.driver_id=driver_locations.driver_id and j.status in ('en_route','picked_up')
 and (j.client_id=(select auth.uid()) or j.driver_id=(select auth.uid()))));

create table public.job_driver_releases (
 id uuid primary key default gen_random_uuid(),
 job_id uuid not null references public.jobs(id) on delete cascade,
 driver_id uuid references auth.users(id) on delete set null,
 origin text not null,
 destination text not null,
 reason text not null check(char_length(btrim(reason)) between 10 and 300),
 created_at timestamptz not null default now()
);
create index job_driver_releases_job_id_idx on public.job_driver_releases(job_id,created_at desc);
create index job_driver_releases_driver_id_idx on public.job_driver_releases(driver_id,created_at desc);
alter table public.job_driver_releases enable row level security;
revoke all on public.job_driver_releases from public,anon,authenticated;
grant select on public.job_driver_releases to authenticated;
create policy "Participants can view driver releases" on public.job_driver_releases for select to authenticated
 using (driver_id=(select auth.uid()) or private.is_admin()
 or exists(select 1 from public.jobs j where j.id=job_id and j.client_id=(select auth.uid())));

create or replace function private.record_job_driver_release()
returns trigger language plpgsql security definer set search_path=''
as $audit$
begin
 if old.status='en_route' and new.status='requested' and old.driver_id is not null and new.driver_id is null then
  insert into public.job_driver_releases(job_id,driver_id,origin,destination,reason)
   values(new.id,old.driver_id,new.origin,new.destination,new.release_reason);
  insert into public.notifications(user_id,title,message,type,job_id)
   select p.id,'Solicitud disponible','Un servicio fue liberado y vuelve a estar disponible.','info',new.id
   from public.profiles p where p.role='driver';
 end if;
 return new;
end;
$audit$;
revoke all on function private.record_job_driver_release() from public,anon,authenticated;
create trigger record_job_driver_release after update on public.jobs
 for each row execute function private.record_job_driver_release();
notify pgrst, 'reload schema';

 $ddl$;
 if jobs_before is distinct from (select md5(coalesce(string_agg((to_jsonb(j)-'release_reason')::text,'' order by id),'')) from public.jobs j) then
  raise exception 'Migration changed existing job data';
 end if;
end;
$migration$;

