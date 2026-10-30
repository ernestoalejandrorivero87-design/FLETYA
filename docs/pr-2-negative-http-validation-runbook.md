# FLETYA PR #2 — real-token negative HTTP validation checklist

**Environment:** FLETYA-testing only (`ccdtpwvalqznasstnqxj`). Never use production, personal accounts, or a live customer job. This document is a runbook, **not execution evidence**.

## Preconditions
1. Verify project URL and publishable key belong to FLETYA-testing. Keep API keys, passwords, refresh tokens and access tokens out of Git, logs and screenshots.
2. Create disposable Auth client A, client B, driver A and driver B accounts with confirmed test sessions. Use only test-owned email addresses and credentials; do not use existing owner accounts.
3. Create isolated test jobs and GPS/notification fixtures as necessary. Record their UUIDs and baseline counts in local ephemeral storage; avoid personally identifying values in committed evidence.
4. Confirm all target rows belong to the disposable fixtures. Prefer reversible, no-op updates (`column=column`) and record the returned row count. A rejected request may return HTTP 200 with an empty result, not necessarily HTTP 403.
5. Authenticate each request using that account's actual Supabase Auth access token and the testing project's publishable key. Do not substitute SQL `SET ROLE` or synthetic JWT claims.

## Required requests and expected outcomes

| Caller | Request | Expected server result |
| --- | --- | --- |
| Client A | PATCH /rest/v1/profiles?id=eq.<client-B-id>, changing a non-role profile field | No row updated, regardless of HTTP 200/403 |
| Client A | PATCH /rest/v1/notifications?id=eq.<client-B-notification-id>, setting `read` | No row updated |
| Client A | PATCH /rest/v1/notifications?id=eq.<client-A-notification-id>, changing `message` | Permission denied; notification content unchanged |
| Driver A | PATCH /rest/v1/jobs?id=eq.<driver-B-assigned-job-id> | No row updated; assignment and state unchanged |
| Driver A | PATCH /rest/v1/driver_locations?id=eq.<driver-B-location-id> | No row updated; coordinates unchanged |
| Driver A | POST /rest/v1/driver_locations for a completed job assigned to driver A | Rejected; no new GPS row |
| Driver A | PATCH /rest/v1/driver_locations for its own historical row on a completed job | Rejected; coordinates unchanged |
| Client A | PATCH /rest/v1/profiles?id=eq.<client-A-id>, attempting `role=admin` | Rejected; profile role remains client |

Use `Prefer: return=representation` and verify both response and independent read-back. For permission-denied requests, expect non-2xx or an empty result depending on RLS/column privileges; **never** infer success from HTTP status alone. For blocked requests, assert both zero changed rows and unchanged persisted values.

## Cleanup and acceptance
- Sign out disposable sessions; delete all temporary fixtures, Auth identities and associated profiles/notifications/GPS rows using privileged test-only cleanup.
- Confirm no temporary identities, rows or helper functions remain, and compare counts to baseline. Do not remove the existing `fletya_session_permission_probe()` until the full real-token evidence is complete.
- Store only sanitized request metadata, HTTP status, response shape, read-back assertions and cleanup confirmation in a separate evidence file.
- If any forbidden operation succeeds, STOP, preserve sanitized evidence and investigate before PR merge.
- Keep PR #2 as draft until these tests, production schema parity, rollback preparation and diagnostic RPC cleanup are complete.

**Current status:** pending. Prior SQL executions with simulated claims do not satisfy this checklist.
