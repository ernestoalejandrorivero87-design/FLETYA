# FLETYA security review and test plan

## Current validation status — 2026-10-26

See [the PR #2 validation record](pr-2-validation-2026-10-26.md) for completed test-environment checks, real client/driver session results, evidence limits, and remaining release gates. The unchecked lists and production findings below are historical planning material; they do not mean that all scenarios remain untested, nor that production has been updated. PR #2 remains a draft with outstanding release work; conflict-resolution progress is recorded in the validation report.

Status: draft only. Do not apply these migrations to production yet.

## Review findings

1. The role guard protects profile role changes, but the trigger path must be verified with the real signup trigger and the existing administrator workflow.
2. The jobs RLS policies restrict which rows a driver can transition, but RLS alone does not restrict which columns can be changed on an allowed row.
3. Column-level grants need to be designed together with the existing app operations. In particular, the admin UI updates jobs.driver_paid; granting that column to every authenticated user would also let an authorized driver update it on rows they can otherwise update. Prefer a narrowly scoped admin-only database function for recording payment, or a trigger that validates changed columns and role.
4. The current app writes GPS rows with an upsert on driver_id, updating job_id, latitude, longitude, accuracy, and updated_at. Any privilege hardening must preserve this flow.
5. The client app creates jobs with origin, destination, distance_km, vehicle_type, helpers, service_type, description, price, and client_id. Driver accept/complete operations update status and driver_id. Test these paths after any grant change.

## Required negative tests

- A signed-out visitor cannot read or modify private profiles, jobs, locations, or notifications.
- A client cannot assign itself the driver or admin role, alter another profile, or create a job for another client.
- A client cannot accept or complete a job, modify driver_paid, or change another client's job.
- A driver cannot change their own role, accept a job already assigned to another driver, change job price/destination/client, mark a driver payment as paid, or modify another driver's GPS row.
- A driver can accept an available requested job, complete their own in-route job, and update their GPS location for that job.
- An administrator retains the intended ability to inspect jobs/profiles and record payment, but only through the authorized path.

## Required positive regression tests

- Sign up a client and a driver; verify the profile role is assigned from the allowed signup metadata.
- Client creates a job; driver sees and accepts it; client sees the status change.
- Driver GPS upsert continues to work.
- Driver completes the service; the client sees completion and the job leaves the active driver list.
- Admin can mark a completed job as paid, and a non-admin cannot.
- Verify the existing admin account and login remain usable.

## Safe validation workflow

1. Review migration SQL and grants statically.
2. Run the database test suite in a local Supabase environment (supabase test db) with a local database, never against production.
3. Test the deployed frontend only against a non-production database before merging.
4. Apply migrations to production only after tests pass and a rollback plan is prepared.

## References

- Supabase RLS and grants: https://supabase.com/docs/guides/database/postgres/row-level-security
- Supabase column-level privileges: https://supabase.com/docs/guides/database/postgres/column-level-security
- Supabase database tests: https://supabase.com/docs/guides/local-development/testing/overview
