# Android driver push delivery

## Scope

Version 0.2 adds Firebase Cloud Messaging for the production Android pilot (`app.fletya.driver`, Firebase project `fletya`). The supplied `google-services.json` is client configuration with public identifiers/API key, not a service-account key. Gradle derives Firebase resource values for `piloto` from this file; `pruebas` has push disabled until its own Firebase app/project is registered. Firebase Messaging BoM is pinned; no Analytics SDK is added.

Device registration is activated only for a signed-in driver with notification permission. The account card provides an independent notification-permission action: GPS is not required to receive an offer. There is no idle polling service and no waiting-state location tracking.

## Delivery flow

1. An existing jobs trigger inserts a driver notification for a new request, or a released job inserts one through its existing audit trigger.
2. A private trigger queues the notification ID, recipient and job ID. Existing records are not backfilled. Delivery starts disabled.
3. On activation, a secret generated inside Vault authenticates `pg_net` calls to the Edge Function. A minute cron retries pending work; each new notification also wakes the sender immediately. Wake failures never fail a freight request.
4. A service-role-only RPC claims a bounded batch with `FOR UPDATE SKIP LOCKED`. It selects only current drivers with enabled devices, a still-present Auth session, no active job, and a still-available requested job. Old events expire instead of producing late alerts.
5. The Edge Function uses a Firebase service account to obtain a short-lived OAuth token and calls FCM HTTP v1. Private credentials remain server-side. Data contains only event/job identifiers, recipient and login nonce, without addresses, names or prices.
6. The Android receiver compares the current local account and per-login nonce before posting the alert. A deduplication set suppresses repeated notification IDs. Tapping opens the home panel, whose ordinary authenticated query checks current availability.
7. Logout first removes the local nonce and visible offer alerts, then attempts server unregistration and Auth logout. Even an offline logout suppresses subsequent messages locally. Old account messages are rejected after a different account signs in.

Delivery is at least once, not an exactly-once guarantee. A network failure after FCM accepts a message may cause retry; Android deduplicates by notification ID. Explicit FCM `UNREGISTERED` responses disable only the exact registration/token that failed, so a rotated replacement is not disabled. Transient failures retry with a bounded count and lease. Do not send Firebase console notification-payload campaigns: those bypass the app's data-message account filtering.

## Required server authorization

1. In Firebase project `fletya`, use Project settings → Service accounts → Firebase Admin SDK to generate the server credential, or configure an equivalent service account permitted to send FCM messages.
2. Store the complete service-account JSON as the Supabase Edge Function secret **`FIREBASE_SERVICE_ACCOUNT_JSON`** in the production project. Never place it in the Android app, `google-services.json`, source control, SQL text or chat. No Google password, recovery code or private account credential is needed.
3. Verify the Firebase Cloud Messaging HTTP v1 API is enabled for the project.
4. Deploy `fletya-driver-push` with JWT gateway verification disabled because it authenticates the Vault webhook secret in the function and its server-only RPC. Public or authenticated app callers cannot claim/ack the queue. Requests with missing/wrong secrets are rejected.
5. Apply the core migration. After the secret is configured, run `scripts/release/activate-driver-push.sql` with the correct `fletya.push_project_url` set in the same SQL call. It enables pg_net/pg_cron, stores the webhook secret in Vault, and schedules bounded retries without printing the secret. Do not activate staging with production credentials.

Until step 5, push delivery is disabled, even if the Android SDK and device registration are ready. This is intentional; no credentials are fabricated and no successful-delivery claim should be made before the end-to-end test.

## Acceptance

- First verify notification permission and that the native account card reports the phone registered.
- With no active job and the native app in the background/phone locked, create a new web-client request. Expect one generic offer alert with sound/vibration according to system/channel settings, without opening the driver app first.
- Tap the alert: refresh the offer list; accepting remains a conditional database update and cannot override an assigned job.
- Release-before-pickup should notify eligible available drivers again through a new notification ID. Do not notify a driver already on another active service.
- Close the native session and create another request: no offer alert on that phone. Repeat while logout is offline and after switching accounts.
- Revoke notification permission, deny it on first sign-in, rotate an FCM token and reconnect after a transient network failure. No GPS should be started for these tests.
- Devices in Android force-stop, offline, without Google Play services or with system notifications disabled cannot be promised immediate delivery.

## Build and signing

Both debug APK variants are generated by the existing Android CI. The previous 0.1 debug APK was built in a transient environment; a later debug build may have a different signing certificate. If Android rejects an update due to incompatible signatures, uninstall the old test APK before installing the new one and sign in again. Account and service data stay in Supabase. Establish persistent distribution signing before external rollout.
