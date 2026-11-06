-- Reviewed PR #2 release. PRODUCTION wsdfqscrvfygxripmrzi only, after explicit approval.
-- One DO statement is atomic; any failed assertion rolls back the entire release.
-- Execute through apply_migration(name=fletya_authorization_release); record its
-- generated version as the consolidated application of the six sources below.
-- Do not run CLI db push against these six files without reconciling that history.
DO $fletya_release$
DECLARE before_data jsonb; after_data jsonb;
BEGIN
PERFORM set_config('lock_timeout','5s',true);
LOCK TABLE public.profiles, public.jobs, public.notifications, public.driver_locations IN SHARE ROW EXCLUSIVE MODE;
IF to_regprocedure('public.is_admin()') IS NULL OR to_regprocedure('public.guard_job_updates()') IS NOT NULL THEN
 RAISE EXCEPTION 'Unexpected release baseline; no changes applied';
END IF;
IF (SELECT count(*) FROM pg_policies WHERE schemaname='public') <> 17 THEN
 RAISE EXCEPTION 'Policy baseline changed; inspect before deployment';
END IF;
select jsonb_build_object('profiles',(select jsonb_agg(to_jsonb(t) order by id) from public.profiles t),'jobs',(select jsonb_agg(to_jsonb(t) order by id) from public.jobs t),'notifications',(select jsonb_agg(to_jsonb(t) order by id) from public.notifications t),'gps',(select jsonb_agg(to_jsonb(t) order by id) from public.driver_locations t)) INTO before_data;

-- Source: supabase/migrations/20261018000000_guard_profile_role_changes.sql
EXECUTE $migration_0$
-- FLETYA security hardening: prevent self-assignment or self-promotion to admin.
-- Review and apply only through a controlled Supabase migration after testing.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  insert into public.profiles (id, full_name, phone, role, email)
  values (
    new.id,
    new.raw_user_meta_data ->> 'full_name',
    new.raw_user_meta_data ->> 'phone',
    case
      when new.raw_user_meta_data ->> 'role' = 'driver' then 'driver'
      else 'client'
    end,
    new.email
  );

  return new;
end;
$function$;

create or replace function public.guard_profile_role_changes()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  if tg_op = 'INSERT' then
    -- A profile insert nested inside the trusted auth.users signup trigger is allowed.
    -- A direct API insert from an ordinary signed-in user is rejected.
    if pg_trigger_depth() = 1
       and auth.uid() is not null
       and not public.is_admin() then
      raise exception 'Profiles are created by the sign-up process';
    end if;
  elsif new.role is distinct from old.role
        and auth.uid() is not null
        and not public.is_admin() then
    raise exception 'Only an administrator can change profile roles';
  end if;

  return new;
end;
$function$;

revoke all on function public.guard_profile_role_changes() from public;
revoke all on function public.guard_profile_role_changes() from anon;
revoke all on function public.guard_profile_role_changes() from authenticated;

drop trigger if exists guard_profile_role_changes on public.profiles;
create trigger guard_profile_role_changes
before insert or update of role on public.profiles
for each row
execute function public.guard_profile_role_changes();

$migration_0$;

-- Source: supabase/migrations/20261018001000_enforce_roles_in_rls.sql
EXECUTE $migration_1$
-- FLETYA authorization hardening: enforce account roles in RLS.
-- Draft only: test in staging before applying to production.

-- Profile rows are created by the trusted auth.users trigger; public clients must not insert them directly.
drop policy if exists "Users can create their own profile" on public.profiles;

drop policy if exists "Clients can create their own jobs" on public.jobs;
create policy "Clients can create their own jobs"
on public.jobs
for insert
to authenticated
with check (
  auth.uid() = client_id
  and status = 'requested'
  and driver_id is null
  and exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'client'
  )
);

drop policy if exists "Drivers can view available jobs" on public.jobs;
create policy "Drivers can view available jobs"
on public.jobs
for select
to authenticated
using (
  (
    status = 'requested'
    and driver_id is null
    and exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'driver'
    )
  )
  or (
    driver_id = auth.uid()
    and exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'driver'
    )
  )
);

drop policy if exists "Drivers can accept available jobs v2" on public.jobs;
create policy "Drivers can accept available jobs v2"
on public.jobs
for update
to authenticated
using (
  status = 'requested'
  and driver_id is null
  and exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'driver'
  )
)
with check (
  status = 'en_route'
  and driver_id = auth.uid()
  and exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'driver'
  )
);

drop policy if exists "Drivers can complete their jobs" on public.jobs;
create policy "Drivers can complete their jobs"
on public.jobs
for update
to authenticated
using (
  status = 'en_route'
  and driver_id = auth.uid()
  and exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'driver'
  )
)
with check (
  status = 'completed'
  and driver_id = auth.uid()
  and exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'driver'
  )
);

drop policy if exists "driver_insert_location" on public.driver_locations;
create policy "driver_insert_location"
on public.driver_locations
for insert
to authenticated
with check (
  auth.uid() = driver_id
  and exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'driver'
  )
  and exists (
    select 1 from public.jobs j
    where j.id = job_id
      and j.driver_id = auth.uid()
      and j.status = 'en_route'
  )
);

drop policy if exists "driver_update_location" on public.driver_locations;
create policy "driver_update_location"
on public.driver_locations
for update
to authenticated
using (
  auth.uid() = driver_id
  and exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'driver'
  )
)
with check (
  auth.uid() = driver_id
  and exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'driver'
  )
  and exists (
    select 1 from public.jobs j
    where j.id = job_id
      and j.driver_id = auth.uid()
      and j.status = 'en_route'
  )
);

$migration_1$;

-- Source: supabase/migrations/20261018002000_restrict_security_definer_execution.sql
EXECUTE $migration_2$
-- Reduce direct API execution of SECURITY DEFINER helpers.
-- Draft only: validate trigger behavior in staging before production.
-- is_admin() must remain executable by authenticated users because RLS policies call it.
revoke all on function public.is_admin() from public;
revoke all on function public.is_admin() from anon;
grant execute on function public.is_admin() to authenticated;

-- These functions are designed to run as database triggers, not as client RPC calls.
revoke all on function public.handle_new_user() from public;
revoke all on function public.handle_new_user() from anon;
revoke all on function public.handle_new_user() from authenticated;

revoke all on function public.notify_drivers_new_job() from public;
revoke all on function public.notify_drivers_new_job() from anon;
revoke all on function public.notify_drivers_new_job() from authenticated;

$migration_2$;

-- Source: supabase/migrations/20261018003000_guard_job_update_columns.sql
EXECUTE $migration_3$
-- Defense in depth: an UPDATE policy limits rows, not columns.
-- Keep driver transitions narrow and reserve payment updates for administrators.
-- Draft only; validate in a local Supabase database before production.

create or replace function public.guard_job_updates()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  actor_role text;
  is_service_role boolean := coalesce(auth.role(), '') = 'service_role';
begin
  -- Trusted server-side jobs may use the service role. RLS still applies to clients.
  if is_service_role then
    return new;
  end if;

  if auth.uid() is null then
    raise exception 'A signed-in user is required to modify a job';
  end if;

  select p.role into actor_role
  from public.profiles p
  where p.id = auth.uid();

  -- Client-created requests must start unassigned and unpaid.
  if tg_op = 'INSERT' then
    if actor_role is distinct from 'client'
      or new.client_id is distinct from auth.uid()
      or new.status is distinct from 'requested'
      or new.driver_id is not null
      or coalesce(new.driver_paid, false) <> false then
      raise exception 'Clients may only create their own new, unassigned, unpaid requests';
    end if;
    new.driver_paid := false;
    return new;
  end if;

  if actor_role = 'admin' and public.is_admin() then
    -- Admin UI currently records payment only. Do not let that path edit job details.
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
    then
      raise exception 'Administrators may only change the payment flag through this app';
    end if;

    if new.driver_paid is distinct from old.driver_paid
       and not (old.status = 'completed' and coalesce(old.driver_paid, false) = false and new.driver_paid = true) then
      raise exception 'Only unpaid completed jobs can be marked as paid';
    end if;

    return new;
  end if;

  if actor_role = 'driver' then
    -- A driver may only accept an unassigned request or complete their own in-route job.
    if new.id is distinct from old.id
      or new.origin is distinct from old.origin
      or new.destination is distinct from old.destination
      or new.distance_km is distinct from old.distance_km
      or new.vehicle_type is distinct from old.vehicle_type
      or new.helpers is distinct from old.helpers
      or new.service_type is distinct from old.service_type
      or new.description is distinct from old.description
      or new.price is distinct from old.price
      or new.client_id is distinct from old.client_id
      or new.created_at is distinct from old.created_at
      or new.updated_at is distinct from old.updated_at
      or new.driver_paid is distinct from old.driver_paid
    then
      raise exception 'Drivers cannot edit job details or payment flags';
    end if;

    if old.status = 'requested'
      and old.driver_id is null
      and new.status = 'en_route'
      and new.driver_id = auth.uid() then
      return new;
    end if;

    if old.status = 'en_route'
      and old.driver_id = auth.uid()
      and new.status = 'completed'
      and new.driver_id = old.driver_id then
      return new;
    end if;

    raise exception 'Drivers may only accept available jobs or complete their own in-route job';
  end if;

  raise exception 'This account is not authorized to update jobs';
end;
$function$;

revoke all on function public.guard_job_updates() from public;
revoke all on function public.guard_job_updates() from anon;
revoke all on function public.guard_job_updates() from authenticated;

drop trigger if exists guard_job_updates on public.jobs;
create trigger guard_job_updates
before insert or update on public.jobs
for each row
execute function public.guard_job_updates();

$migration_3$;

-- Source: supabase/migrations/20261018004000_restrict_table_privileges.sql
EXECUTE $migration_4$
-- Remove unnecessary table privileges from public API roles.
-- Draft only: review and test locally before applying to any live database.
-- RLS does not govern TRUNCATE; table-level grants must be minimized separately.

revoke all privileges on table public.profiles from anon;
revoke all privileges on table public.jobs from anon;
revoke all privileges on table public.driver_locations from anon;
revoke all privileges on table public.notifications from anon;

-- The app has no client-side delete/truncate/trigger/reference workflow.
-- Rebuild only the CRUD grants used by the current browser app.
revoke all privileges on table public.profiles from authenticated;
revoke all privileges on table public.jobs from authenticated;
revoke all privileges on table public.driver_locations from authenticated;
revoke all privileges on table public.notifications from authenticated;

grant select, update on table public.profiles to authenticated;
grant select, insert, update on table public.jobs to authenticated;
grant select, insert, update on table public.driver_locations to authenticated;
-- Clients may mark their own notifications as read, but cannot rewrite their content.
grant select on table public.notifications to authenticated;
grant update (read) on table public.notifications to authenticated;

-- Tables and sequences created later by the normal migration owner (postgres)
-- should not automatically expose full privileges to browser API roles.
-- Future migrations must grant only the exact operations they require.
alter default privileges for role postgres in schema public
  revoke all privileges on tables from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke all privileges on sequences from anon, authenticated;

-- Profile creation is performed by the trusted auth.users trigger.
-- No INSERT privilege is granted on profiles to authenticated clients.

$migration_4$;

-- Source: supabase/migrations/20261022090000_move_is_admin_to_private_schema.sql
EXECUTE $migration_5$
-- Keep the admin helper available to RLS without exposing it as a public PostgREST RPC.
-- Apply in non-production first and verify administrator profile access before any production rollout.

create schema if not exists private;
revoke all on schema private from public;
revoke all on schema private from anon;
revoke all on schema private from authenticated;
grant usage on schema private to authenticated;

create or replace function private.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and role = 'admin'
  )
$function$;

revoke all on function private.is_admin() from public;
revoke all on function private.is_admin() from anon;
grant execute on function private.is_admin() to authenticated;

alter policy "Admins can view all profiles"
  on public.profiles
  using (private.is_admin());

create or replace function public.guard_profile_role_changes()
returns trigger
language plpgsql
security definer
set search_path = 'public'
as $function$
begin
  if tg_op = 'INSERT' then
    if pg_trigger_depth() = 1 and auth.uid() is not null and not private.is_admin() then
      raise exception 'Profiles are created by the sign-up process';
    end if;
  elsif new.role is distinct from old.role and auth.uid() is not null and not private.is_admin() then
    raise exception 'Only an administrator can change profile roles';
  end if;
  return new;
end;
$function$;

create or replace function public.guard_job_updates()
returns trigger
language plpgsql
security definer
set search_path = 'public'
as $function$
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
      or coalesce(new.driver_paid, false) <> false then
      raise exception 'Clients may only create their own new, unassigned, unpaid requests';
    end if;
    new.driver_paid := false;
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
      or new.updated_at is distinct from old.updated_at then
      raise exception 'Administrators may only change the payment flag through this app';
    end if;

    if new.driver_paid is distinct from old.driver_paid
       and not (old.status = 'completed' and coalesce(old.driver_paid, false) = false and new.driver_paid = true) then
      raise exception 'Only unpaid completed jobs can be marked as paid';
    end if;
    return new;
  end if;

  if actor_role = 'driver' then
    if new.id is distinct from old.id
      or new.origin is distinct from old.origin
      or new.destination is distinct from old.destination
      or new.distance_km is distinct from old.distance_km
      or new.vehicle_type is distinct from old.vehicle_type
      or new.helpers is distinct from old.helpers
      or new.service_type is distinct from old.service_type
      or new.description is distinct from old.description
      or new.price is distinct from old.price
      or new.client_id is distinct from old.client_id
      or new.created_at is distinct from old.created_at
      or new.updated_at is distinct from old.updated_at
      or new.driver_paid is distinct from old.driver_paid then
      raise exception 'Drivers cannot edit job details or payment flags';
    end if;

    if old.status = 'requested' and old.driver_id is null
      and new.status = 'en_route' and new.driver_id = auth.uid() then
      return new;
    end if;

    if old.status = 'en_route' and old.driver_id = auth.uid()
      and new.status = 'completed' and new.driver_id = old.driver_id then
      return new;
    end if;

    raise exception 'Drivers may only accept available jobs or complete their own in-route job';
  end if;

  raise exception 'This account is not authorized to update jobs';
end;
$function$;

drop function public.is_admin();

$migration_5$;

select jsonb_build_object('profiles',(select jsonb_agg(to_jsonb(t) order by id) from public.profiles t),'jobs',(select jsonb_agg(to_jsonb(t) order by id) from public.jobs t),'notifications',(select jsonb_agg(to_jsonb(t) order by id) from public.notifications t),'gps',(select jsonb_agg(to_jsonb(t) order by id) from public.driver_locations t)) INTO after_data;
IF before_data IS DISTINCT FROM after_data THEN RAISE EXCEPTION 'Release changed application rows; rolling back'; END IF;
IF to_regprocedure('public.is_admin()') IS NOT NULL OR to_regprocedure('private.is_admin()') IS NULL THEN RAISE EXCEPTION 'Admin helper was not hardened'; END IF;
IF (SELECT count(*) FROM pg_policies WHERE schemaname='public') <> 16 THEN RAISE EXCEPTION 'Unexpected final policy count'; END IF;
IF EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname IN ('profiles','jobs','notifications','driver_locations') AND NOT c.relrowsecurity) THEN RAISE EXCEPTION 'RLS missing'; END IF;
IF EXISTS(SELECT 1 FROM information_schema.role_table_grants WHERE table_schema='public' AND grantee IN ('anon','authenticated') AND privilege_type IN ('TRUNCATE','DELETE','TRIGGER','REFERENCES')) THEN RAISE EXCEPTION 'Broad API grants remain'; END IF;
IF to_regprocedure('public.fletya_session_permission_probe()') IS NOT NULL THEN RAISE EXCEPTION 'Test RPC must not be in production'; END IF;
END
$fletya_release$;
