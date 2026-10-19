# FLETYA security validation checklist

This checklist is intentionally non-destructive. No SQL in this file is intended to run against production.

## Static review gate — must pass before local tests

- [ ] Enumerate every policy on public.jobs in the target schema. PostgreSQL permissive policies combine with OR, so dropping one named policy does not neutralize another broad UPDATE policy that remains active.
- [ ] Confirm the names of all existing policies before relying on DROP POLICY statements. The migration currently drops specific names; verify each is the intended policy and no legacy policy grants equivalent access.
- [ ] Review the jobs update trigger alongside all existing jobs policies and grants.
- [ ] Verify role names are consistent everywhere: the app uses client, driver, and admin; the job status values in the live schema must include requested, en_route, and completed (the app also filters accepted in one place, so verify whether accepted is a real status or stale UI logic).
- [ ] Verify the actual profiles and jobs column types, defaults, triggers, and constraints against the migration assumptions.
- [ ] Verify driver_locations upsert on conflict (driver_id) remains valid and that the intended unique constraint exists.
- [ ] Verify the existing auth.users profile-creation trigger calls handle_new_user() and test signup with both client and driver metadata.
- [ ] Verify admin payment update is restricted to completed jobs where driver_paid changes false -> true.

## Local regression cases

### Roles and profiles
- [ ] Client signup creates a client profile.
- [ ] Driver signup creates a driver profile.
- [ ] Public signup metadata cannot create an admin profile.
- [ ] Client and driver cannot change their own role or another user's role.
- [ ] Existing admin login and profile lookup continue to work.

### Jobs
- [ ] Client creates a requested job with driver_id null.
- [ ] Client cannot create a job on behalf of another client or create it as already assigned/completed.
- [ ] Driver sees available requested jobs and accepts one atomically.
- [ ] Two drivers racing to accept the same job cannot both succeed.
- [ ] Driver cannot edit price, origin, destination, client_id, driver_paid, or other job details.
- [ ] Driver completes only their own en_route job.
- [ ] Client cannot update job status, driver_id, price, or another client's job.
- [ ] Admin can list the intended records and mark only a completed unpaid job as paid.
- [ ] Non-admin cannot set driver_paid.

### GPS and notifications
- [ ] Driver GPS upsert works for the active job.
- [ ] Driver cannot write GPS rows for another driver.
- [ ] Client associated with an en_route job can read the intended live location.
- [ ] Unrelated users cannot read another job's location or notifications.

## Local execution

1. Install Docker Desktop and the Supabase CLI, if not already installed.
2. Initialize Supabase local configuration in a separate working copy; do not use production credentials for local testing.
3. Start the local stack and apply migrations to the local database only.
4. Add runnable pgTAP tests for the exact schema and policy names, then run `supabase test db`.
5. Test the frontend against local Supabase credentials and test accounts.
6. Do not merge or apply migrations until the test suite passes and the policy inventory is reviewed.

## Safety status

- The migration files are in the GitHub branch `fix/security-profile-role`.
- No migrations from this branch have been applied to production.
- Automated database tests have not yet been executed. This repository currently has no Supabase local config or test suite on the reviewed branch, so executable tests must be added after schema/policy inventory is confirmed.
