# PR #2 release preparation — 2026-11-06

## Verified

- Manual real-session HTTP validation and cleanup are recorded in
  [the session evidence](pr-2-session-checks-2026-11-06.md).
- Commit 717e85a8a0978b45b0a7837a86bc8fc65d63adca passed GitHub Actions runs
  [42245122718](https://github.com/ernestoalejandrorivero87-design/FLETYA/actions/runs/42245122718),
  [42245114623](https://github.com/ernestoalejandrorivero87-design/FLETYA/actions/runs/42245114623), and
  [42245122787](https://github.com/ernestoalejandrorivero87-design/FLETYA/actions/runs/42245122787).
  These include disposable PostgreSQL integration; they are not production tests.
- Test-only diagnostics are no longer loaded by the application or callable in
  FLETYA-testing. Eight disposable users and five jobs were removed; all other
  application rows were preserved by the cleanup transaction.

## Schema source reconciliation

The current testing handle_new_user() copies auth.users.email into profiles.email.
The original draft migration omitted that email assignment. The migration and
the disposable Auth fixture were aligned to the already-tested behavior; the
integration suite now explicitly verifies profile email preservation.
This edits an unapplied production draft; it is not a claim that an already-applied
database migration was rerun. Testing migration history uses generated versions
different from the repository filenames; compare definitions, not version names alone.

## Production inspection

Production project: wsdfqscrvfygxripmrzi; testing: ccdtpwvalqznasstnqxj.
Production was inactive and a read-only SQL attempt returned database inaccessible.
The restore request was accepted so its catalog could be inspected. While it is
COMING_UP, parity cannot be certified. No production schema/data migrations or PR
merge have been performed.

Use [release-catalog-inventory.sql](../tests/security/release-catalog-inventory.sql)
to capture metadata from both projects. Compare column types/defaults, constraints,
all permissive/restrictive policies, table/column grants, function definitions and
ACLs, triggers and default privileges. Check Data API exposed schemas separately:
the private schema must not be exposed. Refresh the production migration history
and security advisors after production becomes available. Never apply the test
bootstrap, archived preview probes or cleanup SQL to production.

## Deployment gates and order

1. Confirm the exact reviewed PR commit and all required CI checks on that commit.
2. Complete live production catalog/migration/ACL parity and resolve unexpected
   legacy policies before choosing the migration sequence. Confirm profiles.email
   exists before the reconciled signup migration is applied.
3. Verify a current backup and a usable restore method for production. Capture its
   prior function/policy/trigger/grant definitions for scoped recovery. Backup
   existence and recovery capability have not yet been verified.
4. Review Auth leaked-password protection, currently disabled in testing. Confirm
   the production setting and available plan before changing it.
5. Obtain approval for the concrete production migration and merge. Apply the six
   reviewed security migrations in their filename order using a controlled change
   process, with transaction boundaries chosen to avoid exposing intermediate
   public admin helpers. Record the actual migration versions and check definitions
   immediately afterward. Do not infer deployment merely from matching filenames.
6. Verify signup (client/driver/admin spoof), existing administrator access, service
   creation, acceptance, GPS, completion and payment restrictions using dedicated
   smoke-test accounts. Confirm advisors and remove these test fixtures afterward.
7. Publish the reviewed frontend to the production host only after database
   hardening passes. The hostname selects its Supabase project; verify the actual
   deployed hostname and backend URL. The testing host must continue using testing.

## Recovery

- If a migration transaction fails before commit, roll it back; do not publish the
  new frontend against a partially applied schema.
- If frontend behavior regresses after deployment, restore the previous reviewed
  Vercel deployment while retaining database protections if compatible. Validate
  login, service transitions and admin access rather than assuming compatibility.
- For a post-commit database issue, use a reviewed forward correction or the
  verified backup/restore procedure. Do not restore broad anon/authenticated grants
  or remove RLS simply to make the UI work. A production rollback is not ready
  until the live baseline and restore capability are verified.
