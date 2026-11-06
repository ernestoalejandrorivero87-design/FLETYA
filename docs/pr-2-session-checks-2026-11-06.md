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
row if the RLS rule unexpectedly regresses. These v3 requests await owner execution.

Still pending: remaining negative HTTP cases in the runbook (including
client notifications and v3 GPS writes after completion); independent read-back;
cleanup of disposable accounts/data and the diagnostic UI/RPC; production parity
review and deployment/rollback preparation. No production migration or merge was
performed for this work.
