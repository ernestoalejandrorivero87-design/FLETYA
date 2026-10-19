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
      or new.status <> 'requested'
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
