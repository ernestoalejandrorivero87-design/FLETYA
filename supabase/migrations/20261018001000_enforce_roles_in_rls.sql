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
);
