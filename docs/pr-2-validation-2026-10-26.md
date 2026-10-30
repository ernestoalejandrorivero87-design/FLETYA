# PR #2 validation record — 2026-10-26

Status: validated for the scenarios below in the non-production FLETYA-testing project. Release review is still pending.

## Environment and evidence

- Repository: ernestoalejandrorivero87-design/FLETYA; branch: fix/security-profile-role.
- Validated frontend head: a1a20fda4329787769f03b2a474cd2c9c7d5fe62.
- Test Supabase project: ccdtpwvalqznasstnqxj. No production schema or data changes were made during this validation.
- Preview: https://fletya-git-fix-security-profile-role-fletya.vercel.app/
- Session diagnostic: the same preview with /#comprobar-permisos.
- Evidence combines direct database checks, HTTP response checks, and screenshots supplied by the project owner during manual browser tests. Screenshots were inspected in the working conversation; they have not been attached to GitHub. No passwords or access tokens were collected or included in this record.

## Results

| Scenario | Result | Evidence and limits |
| --- | --- | --- |
| Automatic driver panel refresh | Passed in manual test | With two phones, a new client request appeared on the driver panel without a manual refresh. |
| Acceptance and client status | Passed in manual test | Driver acceptance changed the client view to En camino automatically. |
| Automatic GPS | Passed in manual test | Location appeared and changed during the active service. This does not establish reliable background tracking with the browser closed. |
| Service completion | Passed in manual test | GPS updates stopped; the client saw Completado and the route line disappeared; completion survived reload. |
| Client tracking message | Fixed and manually verified | Completed services no longer show Buscando ubicación del fletero. Pending GPS responses cannot restore the completed service's tracking text. |
| Administrator service details | Passed in manual test | Administrator could inspect the completed service and the assigned driver. |
| Administrator payment recording | Passed in manual test | Marking the tested driver's pending services paid reduced that driver's pending amount to zero, preserved the other driver's pending amount, and survived reload. This records payment status; no payment transfer was tested. |
| Administrator screen access | Passed in manual test | Client and driver accounts were both refused access. |
| Database role and RLS checks | 43 checks passed | Executed as authenticated/anon database roles with simulated JWT claims, against the real test schema. Covered role escalation, cross-user reads, forbidden job edits/payment flags, assignment ownership, GPS ownership/lifecycle, and allowed client/driver/admin actions. Temporary writes were rolled back. Counts before/after: 8 jobs, 15 notifications, 2 locations; no audit fixture jobs remained. |
| Unauthenticated HTTP access | Passed | Actual Data API calls without a session to profiles and jobs returned HTTP 401 / PostgreSQL code 42501. An invalid token returned HTTP 401 / PGRST301. The diagnostic RPC was also refused to unauthenticated callers. |
| Real client session with active job | Passed in owner screenshot | Auth getUser verified the actual session; direct REST reads did not expose other users' profiles, notifications, or jobs. The SECURITY INVOKER diagnostic RPC checked RLS visibility and rejected role escalation and changes to price, destination, and payment on an en_route job. |
| Real driver session with active job | Passed in owner screenshot | The same session/API/RPC checks passed for the assigned driver on the en_route job. |
| Completion after session permission probes | Passed in owner screenshot | The test service (877.05 MXN) subsequently completed normally, appeared in driver history, and showed no in-route GPS session. |

The session probes use the caller's real Auth token through PostgREST. They do not replace claims or use SECURITY DEFINER. Mutation probes execute inside exception subtransactions that roll back even if an unauthorized mutation unexpectedly succeeds; unexpected successes are reported as failures. Cross-user visibility checks should be supplemented with explicit second-account HTTP tests for each remaining operation. The tested job changes are made inside the RPC, not through raw REST PATCH requests.

## Automated checks

Latest inspected security workflow: [run 40348832042](https://github.com/ernestoalejandrorivero87-design/FLETYA/actions/runs/40348832042), successful on commit 2bff09d904352fe96aa21a5633afc4a59dc3bc95.

This is an ancestor of the validated frontend head, not a claim that the current head ran the full workflow. The workflow's path filters do not run security CI for every HTML or documentation change. JavaScript syntax and mocked UI/error handling were checked locally for the new diagnostic interface. A full automated browser test with real user sessions was not run by the assistant.

## Remaining before release

- [x] Resolve the content conflicts against actual main commit 839c9a95acdb88d7c010edbe6a432e594e63f6a3. The PR metadata initially reported the older base 4c325e7; the main branch ref and local Git history established the current base. Preserve database-backed completion and guarded panel refresh from main, plus GPS shutdown from the PR. Remove duplicate driver polling and repeated state assignments. Local validation: 9 frontend regression tests and 15 migration pattern checks passed. Remote CI results must be checked on the resulting merge commit.
- [x] Owner confirmed normal fresh client and driver signups, confirmation emails and login on October 27. See the October 28 follow-up.
- [x] Public signup with data.role=admin was exercised through actual Auth on October 28. The pending-confirmation account received a client profile; administrator count stayed unchanged. See [evidence and limits](pr-2-signup-role-2026-10-28.md).
- [x] Two actual Auth sessions competed through simultaneous HTTP PATCH requests on October 28. Server-side lock observation confirmed overlap; exactly one received the assignment. See [concurrency evidence](pr-2-concurrency-2026-10-28.md).
- [ ] Complete remaining negative API coverage: fresh-signup metadata escalation, writing another user's profile/notifications/GPS, and GPS writes after completion using actual end-user HTTP requests.
- [ ] Review production schema, grants, policies, triggers, migration history/order, and differences from FLETYA-testing before selecting a deployment sequence. Do not treat the historical October 18 metadata snapshot as a current production audit.
- [ ] Prepare and review deployment and rollback steps, including database recovery and the previous frontend revision. Reverting a frontend commit alone does not undo database migrations.
- [ ] Review the Auth leaked-password-protection warning. The test project's latest security advisor reported this warning; no new advisor warnings were introduced by the probe. No Auth settings were changed.
- [ ] Remove the temporary session diagnostic UI/page and revoke/drop public.fletya_session_permission_probe() in FLETYA-testing after retaining the required evidence. Do not install this test-only function in production or put it in production migrations.

Production deployment and PR merge have not been performed. Passing these scenarios is not a complete security audit or a guarantee against every unauthorized action.

## Conflict-resolution follow-up

The merge is made into the PR branch, with both the previous PR head and main as parents; main and production are not updated. The session diagnostic and previously validated security migrations remain in the branch. The security workflow now runs the frontend regression tests and also triggers on index.html changes, so future frontend changes do not silently skip these checks. Regression cases cover stale local service state, database errors and zero-row completion responses, GPS and timer shutdown, hidden or changed-account refreshes, duplicate polling, and restoration of active service/history. Browser screenshots above predate this integration; a short manual preview smoke test should follow the automated checks.

## October 28 follow-up

The owner-confirmed post-integration service smoke test and normal fresh registrations passed. Controlled concurrent HTTP acceptance also passed, and the losing-driver success message was corrected. Details, limitations and cleanup verification are recorded in [the concurrency follow-up](pr-2-concurrency-2026-10-28.md). Remaining release gates above still apply.

## Public signup role check — October 28

A real unauthenticated signup request with admin metadata created a client application profile. The temporary account was removed and baseline counts were restored. See [the public signup validation record](pr-2-signup-role-2026-10-28.md) for the confirmation-stage limit and sanitized evidence.

## October 30 follow-up — read-only permissions audit

- On FLETYA-testing, checked effective table privileges for anon and authenticated across profiles, jobs, notifications and driver_locations. All four tables have RLS enabled. Neither role has DELETE or TRUNCATE privileges; anon has no direct table privileges on these four tables.
- Authenticated has SELECT/UPDATE on profiles and notifications, SELECT/INSERT/UPDATE on jobs and driver_locations. Importantly, authenticated does **not** have INSERT on notifications, even though a legacy INSERT policy exists; the policy alone does not confer table privileges. No migration is needed to remove that policy as an urgent security fix.
- Inspected profiles, notifications and driver_locations RLS policy expressions. GPS insert/update WITH CHECK requires an assigned en_route job and the driver's own identity. These are policy-level observations, **not** completed negative cross-account HTTP tests.
- Supabase security advisor still reports leaked-password protection disabled (one warning). No configuration changed.
- Temporary diagnostics were removed from index.html and security-check.html on the PR branch. The test-only `public.fletya_session_permission_probe()` remains in FLETYA-testing pending final HTTP evidence; do not ship it to production.
- Still required: negative real end-user HTTP mutation tests, production parity/deployment/rollback review, and post-cleanup smoke test. No production changes were made.

## October 30 follow-up — notification column-permission execution test

- After narrowing `authenticated` to `SELECT` plus `UPDATE(read)` on `public.notifications`, executed two SQL operations under `SET LOCAL ROLE authenticated` with a simulated JWT subject belonging to a real client/driver notification owner in FLETYA-testing.
- `UPDATE public.notifications SET message=message WHERE id=...` was denied with insufficient privilege, as expected.
- `UPDATE public.notifications SET read=read WHERE id=...` affected exactly one owned row, as expected.
- The entire exercise was enclosed in `BEGIN ... ROLLBACK`; no notification content or read state was persistently changed. No identifying user or notification IDs were recorded.
- These are actual PostgreSQL privilege/RLS executions with **simulated claims**, not authenticated HTTP requests with real Supabase Auth access tokens. Cross-account negative HTTP tests remain outstanding.
- The notification grant migration and static checker were updated in the PR branch; the CI checks on commit `22de47fce0d0d7402d1cda61d0029c762ed5094c` both passed and Vercel reported success.

## October 30 follow-up — completed-job GPS negative SQL execution

- In FLETYA-testing, found an existing completed job with a historical `driver_locations` row assigned to its driver. Using `SET LOCAL ROLE authenticated` and a simulated JWT subject of that same driver, attempted `UPDATE public.driver_locations SET latitude=latitude WHERE id=...`.
- PostgreSQL rejected the update with SQLSTATE `42501` (insufficient privilege / RLS WITH CHECK rejection), as intended for a completed job. The test was inside `BEGIN ... ROLLBACK` and changed no persistent data.
- This validates a real SQL operation under simulated claims; it **does not** close the outstanding real-token HTTP GPS-after-completion test.
