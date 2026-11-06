# Downloaded production backup validation — 2026-11-06

Input: owner-uploaded `db_cluster-06-11-2026@15-51-33.backup.gz`, downloaded
through the paused production project's Database backup option.
The backup itself, application rows, Auth credentials, tokens and intermediate
data are not committed to this repository.

## Integrity and inventory

- Compressed size: 66,864 bytes; uncompressed size: 414,136 bytes.
- SHA-256: `84f4ff8e35e30468eb8fb3a81051fbfab9c39f52cc5882c5870d13ade0f051cd`.
- Gzip decompression and its integrity check completed without error.
- Format: plain SQL PostgreSQL cluster dump; completion marker present.
- Dump source: PostgreSQL 17.6; pg_dump 17.11.
- Application COPY blocks: profiles 3, jobs 16, notifications 3,
  driver_locations 1. All COPY blocks had terminating markers.
- Auth includes 3 users and 3 identities, plus refresh/session data. These were
  inventoried without displaying or exporting their credential values.
- Storage buckets and objects both contain zero rows in this backup. This does
  not independently verify external Storage object bytes or other hosted settings.

## Isolated application recovery test — passed

An in-memory PGlite 0.5.15 instance (PostgreSQL 18.6) was used because native
PostgreSQL/Docker were not available in the executor. The supported package was
installed at its exact version from npm with lifecycle scripts disabled.

Only the four application tables, their function definitions, primary/foreign
keys, triggers, policies, RLS flags, grants and default privileges were selected
from the dump. The dump's Auth uid()/role() helpers were restored. A minimal
Auth reference table was populated with the three user identifiers/emails needed
by application foreign keys; this was not a full Auth service restore.

Every application row was inserted into the isolated database, and its typed
JSON representation was compared with the corresponding decoded backup COPY
record. All rows matched. Installing the dump's foreign keys succeeded.

The six current draft security migrations were then applied in filename order
to that recovered application schema. They completed successfully; before/after
JSON snapshots of every application row were identical. The final policy count
was 16. No hosted database was modified by this test.

The database was closed after testing and the intermediate decoded row file was
removed. The uploaded original remains unchanged.

The exact consolidated production release in scripts/release/pr-2-production.sql
was subsequently tested on a fresh recovered application instance. Injecting an
intentional exception at its final step verified atomic rollback of the new
functions and restoration of the original admin helper. The unchanged release
then applied successfully, with every original application row preserved. The
second temporary decoded-row file was also removed after testing.

## Limits and release decision

This verifies archive integrity and recoverability of the application data/schema
within the tested scope. It is not a full Supabase cluster restoration and uses
PostgreSQL 18.6 rather than the original Supabase 17.6. Custom managed extensions,
Auth login/session restoration, Storage services, Edge Function secrets, API
settings and an operational hosted restore were not tested.

The native recovery path should use the matching Supabase Postgres image
`17.6.1.166` observed in the download menu and project metadata, following the
[official local-backup recovery guide](https://supabase.com/docs/guides/local-development/restoring-downloaded-backup).
For recovery to a hosted project, use the official hosted migration/recovery
workflow rather than feeding the full cluster SQL into an existing live project.
Neither workflow has been executed here.

Keep this archive as the pre-migration recovery source. Final release still needs
the production Data API/Auth configuration review, a confirmed operational
recovery method for managed services, and approval for the production changes.
PR #2 remains a draft; no production migration or merge was performed.
