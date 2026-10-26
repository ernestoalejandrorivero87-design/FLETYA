# FLETYA security validation checklist

## Current validation status — 2026-10-26

See [the PR #2 validation record](pr-2-validation-2026-10-26.md) for completed test-environment checks, real client/driver session results, evidence limits, and remaining release gates. The unchecked lists and production findings below are historical planning material; they do not mean that all scenarios remain untested, nor that production has been updated. PR #2 remains a draft with outstanding release work; conflict-resolution progress is recorded in the validation report.

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

## Findings from read-only production metadata inspection (2026-10-18)

- RLS is enabled on profiles, jobs, driver_locations, and notifications; FORCE ROW LEVEL SECURITY is not enabled on these tables.
- The current policy inventory contains the named policies listed in the static review, including client profile self-update and jobs update policies for driver acceptance/completion.
- The current ACLs explicitly grant anon and authenticated broad table privileges, including DELETE, TRUNCATE, REFERENCES, and TRIGGER. RLS does not protect against TRUNCATE, so these grants should be minimized.
- Default privileges for objects created by the normal postgres migration role currently grant broad table/sequence privileges to anon and authenticated. Migration 040 now proposes revoking those default grants for future tables and sequences created by postgres.
- driver_locations has a UNIQUE constraint on driver_id, so the app's upsert conflict target is supported.
- GPS insert/update policies now also require the referenced job to be assigned to that fletero and currently `en_route`; this prevents a driver from attaching their location to someone else's active job.
- Direct authenticated INSERT on notifications is not granted in migration 040 because the reviewed browser app has no live calls to its `createNotification()` helper; the existing database trigger remains the intended notification path. Re-check this if the frontend begins writing notifications directly.
- The live jobs trigger inventory includes trigger_notify_drivers_new_job; auth.users has on_auth_user_created calling handle_new_user.
- The read-only advisor still reports SECURITY DEFINER execution warnings and leaked-password protection disabled. The warnings are expected to remain until a migration is applied; the password setting is an Auth dashboard configuration and is not changed by these SQL files.
- This was metadata-only inspection. No production DDL or data mutation was run.

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

## Automated static gate

- [x] Added `scripts/check-security-migrations.mjs` to check critical migration invariants without connecting to a database.
- [x] Added `.github/workflows/security-static-check.yml` to run those checks on relevant pull-request changes.
- [x] GitHub Actions run 39182064816 completed successfully: static checks and disposable PostgreSQL integration tests passed.
- [ ] Remember: a static pattern check does not prove SQL syntax, RLS behavior, or trigger behavior; PostgreSQL integration tests remain required.

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
- Disposable PostgreSQL integration tests have been executed in GitHub Actions and passed (run 39182064816). They use an approximation of Supabase Auth/RLS, not the actual Supabase runtime. A real local Supabase test remains required before production.


## Follow-up from production parity review (2026-10-18)

- Read-only metadata confirms `handle_new_user()` currently assigns `coalesce(raw_user_meta_data->>'role','client')` without restricting the value. Migration 00000 changes this to an allowlist (`driver` or default `client`), blocking signup metadata from creating an admin profile.
- The live `anon` and `authenticated` ACLs include broad privileges such as DELETE, TRUNCATE, REFERENCES, and TRIGGER on the four app tables. Migration 04000 proposes removing these and rebuilding only the browser app's required grants. Validate all front-end paths after applying in a non-production Supabase instance.
- The current profile update policy allows a user to update their own profile row; the role-change trigger is intended to prevent self-promotion. This must be tested with real Supabase JWT claims, not only the disposable PostgreSQL fixture.
- The existing notification trigger creates notifications on requested jobs. The draft removes direct notification INSERT for browser users; verify signup, job creation, and notification delivery still work after grant changes.
- The production migration-history endpoint returned an empty list during this review. This does not prove that no schema changes exist; compare the actual schema and repository migrations before choosing a deployment sequence.
- No production DDL or data changes were performed during this review.
