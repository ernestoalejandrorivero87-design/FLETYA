# Concurrent service acceptance — 2026-10-28

## Result

Passed in FLETYA-testing (ccdtpwvalqznasstnqxj), using two real Supabase Auth sessions and simultaneous Data API PATCH requests for the same requested job. Production was not accessed or modified for this test.

The earlier MCP-only attempt executed the two updates sequentially. It demonstrated refusal after assignment, but was not accepted as concurrency evidence. This record describes the subsequent HTTP test.

## Method

- Provision two disposable driver identities in the test database, with random credentials and example.com addresses. Bootstrap Auth identities directly for fixtures; no email was sent. Obtain their actual access tokens through the password sign-in endpoint. This fixture setup does not count as a public signup or email-confirmation test.
- Insert a uniquely marked temporary requested job and verify that both drivers can read it.
- Use a temporary SECURITY INVOKER helper, restricted to those two fixture identities and that specific job, to hold a row lock. A transaction-scoped advisory lock provides a readiness signal; the client waits for that signal before starting the two PATCH requests.
- Start both PATCH requests behind a thread barrier. Before releasing the row lock, inspect pg_blocking_pids/pg_stat_activity inside the helper to confirm that two separate waiting backends exist in the blocking chain. This establishes server-side overlap, rather than merely launching two client calls near each other.
- Require exactly one returned assignment and one empty result. Read back the job as the winner; verify that its driver_id matches. Verify that the losing driver can no longer read the assigned job.

## Observed results

| Request shape | Simultaneous blocked backends | Worker A | Worker B | Final owner |
| --- | --- | --- | --- | --- |
| Original PATCH filtered only by job ID | 2 | HTTP 200, 0 rows | HTTP 200, 1 row | B |
| Corrected PATCH: job ID + status=requested + driver_id IS NULL | 2 | HTTP 200, 1 row | HTTP 200, 0 rows | A |

For the corrected request, the row lock was held from 2026-10-28T11:17:36.186921Z through 11:17:41.192150Z. The two client requests started at 11:17:36.232609Z and 11:17:36.232040Z and each waited about five seconds. The losing driver's subsequent GET returned an empty list. See the [sanitized HTTP evidence](../tests/security/evidence/concurrent-acceptance-2026-10-28.json).

This checks one controlled contention case for each request shape. It is not a load test, a two-device browser race, or proof of every retry/reconnection behavior.

## Frontend correction

The original acceptDriver() checked only error. PostgREST legitimately returns HTTP 200 with an empty result when no row is eligible under the current filter/RLS policy, so the losing browser could announce success despite not acquiring a service.

The corrected function:

- Captures the selected job ID before awaiting authentication.
- Requires status=requested and driver_id IS NULL in the update filter.
- Requests the updated row and checks maybeSingle().data.
- Shows an unavailable-service message and refreshes the panel if no assignment is returned; it does not mark the local request accepted.
- Uses the returned assignment as local state and announces success only after an actual returned row.

Four new frontend regression cases cover successful assignment, losing a race, a database permission error, and a selected job changing during authentication. All 13 frontend tests and 15 migration pattern checks passed locally. CI for the resulting commit must also pass before release.

## Cleanup

Both disposable sessions were signed out. The temporary driver identities, profiles, job, generated notifications, and the two helper functions were removed. Temporary credentials were removed from scratch storage and were not committed or printed in this evidence.

Independent final database counts matched the baseline: 10 jobs, 7 profiles, 19 notifications, 2 driver locations. Checks found zero temporary users, zero temporary jobs, and zero temporary helper functions. Existing owner accounts were retained.

## Other owner-confirmed validation

After main was integrated, the owner supplied screenshots of a new service being requested, accepted with GPS, viewed in the client account, then completed and shown in driver history with no in-route GPS session. The tested service was 467.55 MXN.

The owner also confirmed successful fresh client and driver registrations, receipt and use of each confirmation email, and login. The driver used a Gmail plus-address alias, so no additional mailbox was needed. These successful normal registrations do not validate malicious signup metadata; that remains a separate release check.
