# Disposable-session checks — 2026-11-06

Environment: FLETYA-testing only. PR #2 remains a draft.

Owner-provided screenshots show successful runs of the preview diagnostics added
in commit `22e01cc842d147da810041d734f4a3fd1bf323d7` with all four disposable
accounts. Both client/driver pairs had their own in-route service for their final
runs. The initial runs for client B and driver B without a service are not counted
as evidence of job mutation protection.

## Observed results

- All four sessions reported passing profile, notification, job and GPS visibility
  checks and the rollback-only attempt to change their own role to administrator.
- Each account's final run reported passing rollback-only attempts to change its
  own service's price, destination and payment flag.
- All four sessions reported a blocked direct HTTP PATCH to the other same-role
  account's profile, using a null-name no-op guarded by a null-name filter.
- Both driver sessions reported a blocked direct HTTP PATCH to the other driver's
  notification, using an unread no-op guarded by the unread value and owner ID.
- Manual screenshots showed client B did not see client A's service/history, driver
  B did not see driver A's assigned service, and both owners recovered their
  respective services and recorded GPS after signing back in.

## Interpretation and limits

The RPC uses SECURITY INVOKER, the actual caller's Auth session and database
subtransactions to undo its mutation attempts. Its output is not equivalent to
executing a separate REST PATCH for every tested column. The direct PATCH checks
are deliberately no-ops and expect a permission error or zero returned rows.
Independent privileged reads confirmed the target rows existed with matching
filter values before these tests; the no-op checks should not be reused after
fixtures are deleted or altered without a new preflight.

The v2 preview adds direct GET/PATCH checks for the opposite pair's exact job and
GPS row. Owner screenshots confirmed all four sessions passed these checks.
The PATCH assigns the existing driver ID constrained by that same ID in the
filter, so it cannot reassign a service or alter coordinates even if unauthorized
access unexpectedly succeeds. A returned row is a failed check.

Independent privileged read-back after all v2 runs confirmed both services stayed
in route with their original clients, drivers and prices (959.50 and 2506.30),
both payment flags stayed false, profile roles/names stayed unchanged, and GPS
records retained their original driver/job associations.

The owner then completed only pair A's service. A privileged query confirmed A
completed and B still in route. Two subsequent GPS reads for driver A returned
the same updated_at, `2026-11-06T15:10:27.609Z`, consistent with stopped updates
over the observed interval. This does not prove background tracking behavior.

The v3 preview prepares completed-service GPS PATCH and INSERT probes with an
immediate historical-row read-back. INSERT must fail with SQLSTATE 42501; a
duplicate-driver constraint error is inconclusive and fails the check. The
existing unique driver constraint prevents the INSERT from persisting a second
row if the RLS rule unexpectedly regresses. Owner screenshots confirmed both
drivers passed these v3 requests after completing their respective services,
including unchanged historical GPS read-back. Client screenshots confirmed both
services appeared completed in tracking/history, without route lines or GPS
tracking text. The base map remained visible.

Two disposable client notifications were created for the remaining notification
checks, with marker `FLETYA HTTP fixture 2026-11-06`. Owner screenshots confirmed
both clients passed the v4 checks: direct PATCH of the other client's unread
notification, direct no-op PATCH of the owner's notification content, and direct
PATCH attempting role=admin with independent client-side role read-back. If a
role change unexpectedly persists, the probe stops for privileged investigation.
Final privileged read-back confirmed both roles remained client, both notification
contents/read flags remained unchanged, both jobs were completed with original
owners/drivers/prices and unpaid flags, and neither historical GPS timestamp moved
after completion. These notification fixtures must be included in test cleanup.

The preview panel and its executable application script were removed after
evidence collection. The script is archived only as
`tests/security/preview-permission-checks.js` for regression tests. It is not
referenced by the application. The test-only RPC's EXECUTE grants were revoked
from PUBLIC, anon and authenticated. Privilege read-back confirmed neither anon
nor authenticated can execute it. The first DROP request was not executed because
its Supabase confirmation expired. The subsequent authorized cleanup transaction
successfully removed the function.

The eight negative HTTP case categories in the runbook were exercised within the
no-op, real-session and read-back limits above. This is not a blanket guarantee
against all possible authorization vulnerabilities.

## Cleanup confirmation

The cleanup transaction removed the eight exact disposable identities, their five
jobs, associated notifications/GPS and Auth refresh sessions. A snapshot comparison
inside the transaction verified every non-fixture application row was preserved.
Final counts: 7 users, 7 profiles, 10 jobs, 19 notifications and 2 GPS rows. A
separate query confirmed zero matching disposable accounts or jobs and no
diagnostic RPC. Existing access JWTs expire normally; cleanup does not claim
immediate cryptographic invalidation of already-issued JWTs.

Still pending: production parity
review and deployment/rollback preparation. No production migration or merge was
performed for this work.
