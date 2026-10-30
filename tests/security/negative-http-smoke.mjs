// Run only against FLETYA-testing with disposable accounts/fixtures.
// Usage: FLETYA_TEST_URL=... FLETYA_TEST_ANON_KEY=... FLETYA_CLIENT_A_EMAIL=...
// FLETYA_CLIENT_A_PASSWORD=... FLETYA_CLIENT_B_PROFILE_ID=...
// node tests/security/negative-http-smoke.mjs
// Never commit credentials or token-bearing logs.
import assert from 'node:assert/strict';

const env = process.env;
const url = env.FLETYA_TEST_URL;
const key = env.FLETYA_TEST_ANON_KEY;
const email = env.FLETYA_CLIENT_A_EMAIL;
const password = env.FLETYA_CLIENT_A_PASSWORD;
const otherId = env.FLETYA_CLIENT_B_PROFILE_ID;
const expectedActorId = env.FLETYA_CLIENT_A_PROFILE_ID;
const fixtureConfirmed = env.FLETYA_DISPOSABLE_FIXTURES_CONFIRMED === 'YES';
if (![url,key,email,password,otherId,expectedActorId].every(Boolean) || !fixtureConfirmed) {
  console.error('Missing test URL, key, disposable client A credentials, client A and B profile IDs, or FLETYA_DISPOSABLE_FIXTURES_CONFIRMED=YES.');
  process.exit(2);
}
const origin = new URL(url).origin;
assert.match(origin, /^https:\/\//, 'HTTPS required');
assert.match(origin, /supabase\.co$/, 'Only Supabase project URLs allowed');
assert.equal(new URL(url).hostname.split('.')[0], 'ccdtpwvalqznasstnqxj', 'Refusing non-testing project');
assert.match(otherId, /^[0-9a-f]{8}-[0-9a-f-]{27,}$/i, 'Expected UUID');
assert.match(expectedActorId, /^[0-9a-f]{8}-[0-9a-f-]{27,}$/i, 'Expected client A UUID');
// Use a working, independently controlled test mailbox; example.com cannot receive verification mail.

async function request(path, token, options={}) {
  const response = await fetch(new URL(path,origin), {
    ...options,
    headers: {
      apikey:key, Authorization:`Bearer ${token}`,
      ...(options.headers||{}),
    },
  });
  const body=await response.text();
  let data; try {data=JSON.parse(body);} catch {data=body;}
  return {status:response.status,ok:response.ok,data};
}
const login=await fetch(new URL('/auth/v1/token?grant_type=password',origin),{
  method:'POST',headers:{apikey:key,'Content-Type':'application/json'},
  body:JSON.stringify({email,password}),
});
if(!login.ok) throw new Error(`Disposable login failed: HTTP ${login.status}`);
const session=await login.json();
const token=session.access_token;
assert.ok(token,'No access token');
const myId=session.user?.id;
assert.ok(myId,'No authenticated user id');
assert.equal(myId,expectedActorId,'Authenticated account is not the approved disposable client A fixture');
assert.notEqual(myId,otherId,'Cross-account target must differ from actor');

// Confirm that client A cannot read client B's profile, nor update it.
const before=await request(`/rest/v1/profiles?id=eq.${otherId}&select=id`,token);
assert.ok(before.ok, `Read request failed: HTTP ${before.status}`);
assert.deepEqual(before.data,[], 'Client A can see client B profile');
const attempt=await request(`/rest/v1/profiles?id=eq.${otherId}&select=id`,token,{
  method:'PATCH',headers:{'Content-Type':'application/json',Prefer:'return=representation'},
  body:JSON.stringify({full_name:'UNAUTHORIZED_SECURITY_TEST'}),
});
if (attempt.ok) assert.deepEqual(attempt.data,[], 'Cross-account PATCH returned a modified row');
const after=await request(`/rest/v1/profiles?id=eq.${otherId}&select=id`,token);
assert.ok(after.ok);
assert.deepEqual(after.data,[], 'Client A gained visibility after PATCH');
console.log(JSON.stringify({
  test:'client A cannot read or patch client B profile',
  passed:true, read_status:before.status, patch_status:attempt.status,
  patch_rows:Array.isArray(attempt.data)?attempt.data.length:null,
  note:'No credentials or tokens logged',
},null,2));
