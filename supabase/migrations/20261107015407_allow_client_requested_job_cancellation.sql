-- Allow a client to cancel only their own requested, unassigned, unpaid job.
-- No records are modified by this migration. Apply this after the authorization release.
do $migration$
declare
  jobs_before text;
begin
  perform set_config('lock_timeout', '5s', true);
  lock table public.jobs in share row exclusive mode;
  if not (select relrowsecurity from pg_class where oid = 'public.jobs'::regclass)
     or to_regprocedure('private.is_admin()') is null then
    raise exception 'The authorization release must be installed first';
  end if;
  select md5(coalesce(string_agg(to_jsonb(j)::text, '' order by id), ''))
    into jobs_before from public.jobs j;

  execute $guard_definition$
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
$function$

  $guard_definition$;
  revoke all on function public.guard_job_updates() from public, anon, authenticated;

  drop policy if exists "Clients can cancel unassigned requests" on public.jobs;
  create policy "Clients can cancel unassigned requests"
    on public.jobs for update to authenticated
    using (
      client_id = (select auth.uid())
      and status = 'requested'
      and driver_id is null
      and coalesce(driver_paid, false) = false
      and exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'client')
    )
    with check (
      client_id = (select auth.uid())
      and status = 'cancelled'
      and driver_id is null
      and coalesce(driver_paid, false) = false
      and exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'client')
    );

  if jobs_before is distinct from
    (select md5(coalesce(string_agg(to_jsonb(j)::text, '' order by id), '')) from public.jobs j) then
    raise exception 'Job records changed during the migration';
  end if;
end;
$migration$;

