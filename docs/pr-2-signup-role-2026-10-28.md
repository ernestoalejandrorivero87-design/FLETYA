# Public signup role escalation — 2026-10-28

## Result

Passed for the tested payload in FLETYA-testing (ccdtpwvalqznasstnqxj). A real unauthenticated request to /auth/v1/signup submitted data.role = "admin". Supabase Auth created a pending-confirmation account, but the application profile was created as client. No administrator profile was added.

## Evidence

| Check | Observed |
| --- | --- |
| Actual public Auth endpoint | POST /auth/v1/signup |
| HTTP response | 200 |
| Attacker-controlled metadata | role = admin |
| Returned/stored user metadata | role = admin |
| Auth database role | authenticated |
| Trusted app metadata role | absent |
| public.profiles.role | client |
| Access token returned at signup | No |
| Email confirmed at inspection | No |
| Administrator count before/after | 1 / 1 |

The test used a fresh Gmail plus-address alias for the project owner and a randomly generated temporary password. A normal confirmation email could be delivered to that alias; the test did not consume its link. No password, confirmation link, access token or email address is included in the committed evidence.

The existing auth.users insertion trigger invokes public.handle_new_user(). Its role mapping allows driver explicitly and maps other supplied roles to client. The API preserving an untrusted metadata field named role does not grant that application role; public.profiles is the authorization source used by the reviewed policies.

This is an actual public signup test, not a fixture inserted directly into auth.users. It verifies profile assignment before email confirmation. It does not independently exercise the malicious account's confirmation-link/login flow or every possible metadata payload. Normal client and driver confirmation/login flows and signed-in role-change denial were tested separately.

## Cleanup

The exact temporary profile, identity and Auth user were deleted. An independent query found zero remaining rows for that temporary Auth user. Counts returned to the baseline: 7 Auth users, 7 profiles, 1 administrator, 10 jobs, 19 notifications. Temporary credentials were deleted from scratch storage.

No application fix, schema change, Auth configuration change or production operation was needed. The result and limits are recorded in the sanitized [evidence file](security-evidence/signup-role-2026-10-28.json).
