// Server-only FCM HTTP v1 sender. No credentials, token values or payloads are logged.
type Device = { installation_id: string; token: string; registration_nonce: string };
type Offer = { notification_id: string; user_id: string; job_id: string; attempt: number; devices: Device[] };
type ServiceAccount = { project_id: string; client_email: string; private_key: string };
type Runtime = { env: (name: string) => string | undefined; fetch: typeof fetch; now: () => number; crypto: Crypto };

export function fcmMessage(offer: Offer, device: Device) {
  return { message: {
    token: device.token,
    data: { type: 'new_service', notification_id: offer.notification_id, user_id: offer.user_id,
      job_id: offer.job_id, registration_nonce: device.registration_nonce },
    android: { priority: 'HIGH', ttl: '120s', collapse_key: offer.job_id, restricted_package_name: 'app.fletya.driver' },
  } }; // Data-only: app validates current local user + login nonce before showing a notification.
}
export function invalidDevice(body: unknown): boolean {
  const error = (body as { error?: { details?: { errorCode?: string }[] } })?.error;
  return error?.details?.some(detail => detail.errorCode === 'UNREGISTERED') === true;
}
function b64(bytes: Uint8Array): string {
  let binary = ''; for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}
async function accessToken(account: ServiceAccount, runtime: Runtime): Promise<string> {
  const now = Math.floor(runtime.now() / 1000);
  const encode = (value: unknown) => b64(new TextEncoder().encode(JSON.stringify(value)));
  const input = encode({ alg: 'RS256', typ: 'JWT' }) + '.' + encode({
    iss: account.client_email, scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 300,
  });
  const pem = account.private_key.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, '');
  const key = await runtime.crypto.subtle.importKey('pkcs8', Uint8Array.from(atob(pem), c => c.charCodeAt(0)),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const signature = await runtime.crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(input));
  const response = await runtime.fetch('https://oauth2.googleapis.com/token', {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: input + '.' + b64(new Uint8Array(signature)) }),
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw new Error('Google authorization unavailable');
  const value = await response.json();
  if (typeof value.access_token !== 'string' || !value.access_token) throw new Error('Invalid Google authorization');
  return value.access_token;
}
export function handler(runtime: Runtime) {
  return async (request: Request): Promise<Response> => {
    if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 });
    const secret = request.headers.get('x-fletya-push-token') || '';
    if (!/^[a-f0-9]{64}$/.test(secret)) return new Response('Unauthorized', { status: 401 });
    const url = runtime.env('SUPABASE_URL');
    const key = runtime.env('SUPABASE_SERVICE_ROLE_KEY');
    if (!url || !key) return new Response('Sender unavailable', { status: 503 });
    const rpc = async (name: string, body: unknown) => runtime.fetch(url + '/rest/v1/rpc/' + name, {
      method: 'POST', headers: { 'Content-Type': 'application/json', apikey: key, Authorization: 'Bearer ' + key },
      body: JSON.stringify(body), signal: AbortSignal.timeout(10_000),
    });
    let claim: Response;
    try { claim = await rpc('claim_driver_push_batch', { p_secret: secret }); }
    catch { return new Response('Queue unavailable', { status: 503 }); }
    if (claim.status === 401 || claim.status === 403) return new Response('Unauthorized', { status: 401 });
    if (!claim.ok) return new Response('Queue unavailable', { status: 503 });
    const offers: Offer[] = await claim.json();
    const configured = runtime.env('FIREBASE_SERVICE_ACCOUNT_JSON');
    let account: ServiceAccount | null = null, googleToken = '';
    try {
      if (configured) {
        account = JSON.parse(configured);
        if (account?.project_id !== 'fletya' || !account.client_email || !account.private_key) account = null;
      }
      if (account && offers.some(offer => offer.devices.length)) googleToken = await accessToken(account, runtime);
    } catch { account = null; }
    let sent = 0, retried = 0;
    const deadline = runtime.now() + 55_000;
    for (const offer of offers) {
      let retry = offer.devices.length > 0 && (!account || !googleToken);
      const invalid: Device[] = [];
      for (const device of offer.devices) {
        if (!account || !googleToken) break;
        if (runtime.now() > deadline) { retry = true; break; }
        try {
          const response = await runtime.fetch('https://fcm.googleapis.com/v1/projects/fletya/messages:send', {
            method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + googleToken },
            body: JSON.stringify(fcmMessage(offer, device)), signal: AbortSignal.timeout(10_000),
          });
          if (response.ok) sent++;
          else if (invalidDevice(await response.json().catch(() => null))) invalid.push(device);
          else retry = true;
        } catch { retry = true; }
      }
      if (retry) retried++;
      try {
        const finish = await rpc('finish_driver_push', { p_notification_id: offer.notification_id, p_attempt: offer.attempt,
          p_result: retry ? 'retry' : offer.devices.length ? 'sent' : 'skipped', p_invalid_devices: invalid });
        if (!finish.ok) retried++;
      } catch { retried++; }
    }
    return Response.json({ processed: offers.length, sent, retry: retried, configured: Boolean(account) });
  };
}
if (typeof Deno !== 'undefined') Deno.serve(handler({ env: name => Deno.env.get(name), fetch, now: Date.now, crypto }));
