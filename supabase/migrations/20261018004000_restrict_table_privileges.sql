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
grant select, insert, update on table public.notifications to authenticated;

-- Tables and sequences created later by the normal migration owner (postgres)
-- should not automatically expose full privileges to browser API roles.
-- Future migrations must grant only the exact operations they require.
alter default privileges for role postgres in schema public
  revoke all privileges on tables from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke all privileges on sequences from anon, authenticated;

-- Profile creation is performed by the trusted auth.users trigger.
-- No INSERT privilege is granted on profiles to authenticated clients.
