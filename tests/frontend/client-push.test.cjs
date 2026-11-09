const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { stripTypeScriptTypes } = require('node:module');
const crypto = require('node:crypto').webcrypto;
const code = stripTypeScriptTypes(fs.readFileSync('supabase/functions/fletya-client-push/index.ts','utf8')).replace(/export /g,'');
const make = () => {
 const context = {Request,Response,Headers,URLSearchParams,TextEncoder,Uint8Array,ArrayBuffer,AbortSignal,btoa,atob,crypto,Date};
 vm.createContext(context);vm.runInContext(code+'\nglobalThis.api={handler,fcmMessage,invalidDevice};',context);return context.api;
};
const offer = {notification_id:'notification-1',user_id:'client-1',job_id:'job-1',event_type:'client_assigned',attempt:1,devices:[{installation_id:'device-1',token:'synthetic-token',registration_nonce:'login-1'}]};
const request = secret => new Request('https://example.test/push',{method:'POST',headers:secret?{'x-fletya-push-token':secret}:{}});
const env = values => name => values[name];
test('FCM data is scoped to recipient and login, short-lived and contains no address or price',()=>{
 const body=make().fcmMessage(offer,offer.devices[0]);
 assert.equal(body.message.data.user_id,'client-1');assert.equal(body.message.data.registration_nonce,'login-1');
 assert.equal(body.message.android.priority,'HIGH');assert.equal(body.message.android.ttl,'600s');
 assert.equal(body.message.android.restricted_package_name,'app.fletya.client');
 assert.equal(body.message.notification,undefined);assert.equal(body.message.data.origin,undefined);assert.equal(body.message.data.price,undefined);
});
test('invalid token cleanup only handles explicit UNREGISTERED errors',()=>{
 const api=make();assert.equal(api.invalidDevice({error:{details:[{errorCode:'UNREGISTERED'}]}}),true);
 assert.equal(api.invalidDevice({error:{details:[{errorCode:'INVALID_ARGUMENT'}]}}),false);assert.equal(api.invalidDevice(null),false);
});
test('missing or malformed webhook secret is rejected before network access',async()=>{
 let calls=0;const handler=make().handler({env:()=>'',fetch:async()=>{calls++;},now:Date.now,crypto});
 assert.equal((await handler(request())).status,401);assert.equal((await handler(request('bad'))).status,401);assert.equal(calls,0);
});
test('database authorization is required before any Google request',async()=>{
 const calls=[];const handler=make().handler({env:env({SUPABASE_URL:'https://db.example',SUPABASE_SERVICE_ROLE_KEY:'synthetic'}),fetch:async url=>{calls.push(url);return new Response('',{status:403});},now:Date.now,crypto});
 assert.equal((await handler(request('a'.repeat(64)))).status,401);assert.equal(calls.length,1);assert.match(calls[0],/claim_client_push_batch$/);
});
test('missing Firebase server credentials defers eligible offers without pretending to send',async()=>{
 const calls=[];const handler=make().handler({env:env({SUPABASE_URL:'https://db.example',SUPABASE_SERVICE_ROLE_KEY:'synthetic'}),fetch:async(url,options)=>{calls.push({url,body:JSON.parse(options.body)});return Response.json(url.endsWith('claim_client_push_batch')?[offer]:null);},now:Date.now,crypto});
 const value=await(await handler(request('a'.repeat(64)))).json();assert.equal(value.sent,0);assert.equal(value.configured,false);assert.equal(value.retry,1);
 assert.equal(calls[1].body.p_result,'retry');assert.equal(calls.length,2);
});
test('credential diagnostics never return the secret or its contents',async()=>{
 for(const [secret,expected] of [['not-json','invalid_json'],[JSON.stringify({project_id:'wrong'}),'wrong_project'],[JSON.stringify({project_id:'fletya'}),'missing_service_account_fields']]){
  const handler=make().handler({env:env({SUPABASE_URL:'https://db.example',SUPABASE_SERVICE_ROLE_KEY:'synthetic',FIREBASE_SERVICE_ACCOUNT_JSON:secret}),fetch:async()=>Response.json([]),now:Date.now,crypto});
  const value=await(await handler(request('a'.repeat(64)))).json();
  assert.equal(value.configuration,expected);assert.equal(value.configured,false);
  assert.equal(value.private_key,undefined);assert.equal(value.client_email,undefined);
 }
});
test('offers without eligible devices are skipped without contacting Google',async()=>{
 const calls=[];const handler=make().handler({env:env({SUPABASE_URL:'https://db.example',SUPABASE_SERVICE_ROLE_KEY:'synthetic'}),fetch:async(url,options)=>{calls.push({url,body:JSON.parse(options.body)});return Response.json(url.endsWith('claim_client_push_batch')?[{...offer,devices:[]}]:null);},now:Date.now,crypto});
 const value=await(await handler(request('a'.repeat(64)))).json();assert.equal(value.sent,0);assert.equal(calls[1].body.p_result,'skipped');
});
test('Google OAuth and send are server-side, successful delivery is acknowledged',async()=>{
 const pair=await crypto.subtle.generateKey({name:'RSASSA-PKCS1-v1_5',modulusLength:2048,publicExponent:new Uint8Array([1,0,1]),hash:'SHA-256'},true,['sign','verify']);
 const pem='-----BEGIN PRIVATE KEY-----\n'+Buffer.from(await crypto.subtle.exportKey('pkcs8',pair.privateKey)).toString('base64')+'\n-----END PRIVATE KEY-----';
 const calls=[];const handler=make().handler({env:env({SUPABASE_URL:'https://db.example',SUPABASE_SERVICE_ROLE_KEY:'synthetic',FIREBASE_SERVICE_ACCOUNT_JSON:JSON.stringify({project_id:'fletya',client_email:'synthetic@example.test',private_key:pem})}),fetch:async(url,options)=>{
  calls.push({url,body:options.body});
  if(url.endsWith('claim_client_push_batch'))return Response.json([offer]);
  if(url==='https://oauth2.googleapis.com/token')return Response.json({access_token:'google-test-token'});
  if(url.includes('fcm.googleapis.com'))return Response.json({name:'accepted-by-fcm'});
  return Response.json(null);
 },now:()=>1800000000000,crypto});
 const response=await(await handler(request('a'.repeat(64)))).json();assert.equal(response.sent,1);
 assert.match(calls[1].body.toString(),/grant_type=urn/);assert.equal(JSON.parse(calls[3].body).p_result,'sent');
 assert.equal(JSON.parse(calls[2].body).message.data.user_id,'client-1');
});
