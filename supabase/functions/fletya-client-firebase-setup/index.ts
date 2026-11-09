// Release helper: pinned to the existing fletya project and app.fletya.client package.
// Credentials stay server-side; only the public google-services configuration is returned.
type ServiceAccount={project_id:string;client_email:string;private_key:string};
type Runtime={fetch:typeof fetch;now:()=>number;crypto:Crypto};
function b64(bytes: Uint8Array): string {
  let binary = ''; for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}
async function accessToken(account: ServiceAccount, runtime: Runtime): Promise<string> {
  const now = Math.floor(runtime.now() / 1000);
  const encode = (value: unknown) => b64(new TextEncoder().encode(JSON.stringify(value)));
  const input = encode({ alg: 'RS256', typ: 'JWT' }) + '.' + encode({
    iss: account.client_email, scope: 'https://www.googleapis.com/auth/firebase',
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

Deno.serve(async(request:Request)=>{
 if(request.method!=='POST')return new Response('Method not allowed',{status:405});
 const secret=request.headers.get('x-fletya-push-token')||'';
 if(!/^[a-f0-9]{64}$/.test(secret))return new Response('Unauthorized',{status:401});
 const url=Deno.env.get('SUPABASE_URL'),key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
 if(!url||!key)return new Response('Unavailable',{status:503});
 try{
  const auth=await fetch(url+'/rest/v1/rpc/authorize_push_hook',{method:'POST',headers:{'Content-Type':'application/json',apikey:key,Authorization:'Bearer '+key},body:JSON.stringify({p_secret:secret}),signal:AbortSignal.timeout(10000)});
  if(!auth.ok||await auth.json()!==true)return new Response('Unauthorized',{status:401});
  const account=JSON.parse(Deno.env.get('FIREBASE_SERVICE_ACCOUNT_JSON')||'null');
  if(account?.project_id!=='fletya'||typeof account.private_key!=='string')return Response.json({status:'missing_server_configuration'},{status:503});
  const token=await accessToken(account,{fetch,now:Date.now,crypto});
  const headers={Authorization:'Bearer '+token,'Content-Type':'application/json'};
  const root='https://firebase.googleapis.com/v1beta1/projects/fletya/androidApps';
  const list=await fetch(root,{headers,signal:AbortSignal.timeout(10000)});
  if(!list.ok)return Response.json({status:'firebase_permission_required',http_status:list.status},{status:403});
  const data=await list.json();const matches=(data.apps||[]).filter((app:{packageName:string})=>app.packageName==='app.fletya.client');
  if(matches.length>1)return Response.json({status:'ambiguous_app'},{status:409});
  if(matches.length===0){
   const created=await fetch(root,{method:'POST',headers,body:JSON.stringify({packageName:'app.fletya.client',displayName:'FLETYA Cliente'}),signal:AbortSignal.timeout(15000)});
   return Response.json({status:created.ok?'provisioning':'firebase_permission_required',http_status:created.status},{status:created.ok?202:403});
  }
  const app=matches[0];if(typeof app.appId!=='string'||!/^1:[0-9]+:android:[a-f0-9]+$/.test(app.appId))return Response.json({status:'invalid_app'},{status:502});
  const config=await fetch(root+'/'+encodeURIComponent(app.appId)+'/config',{headers,signal:AbortSignal.timeout(10000)});
  if(!config.ok)return Response.json({status:'configuration_pending',http_status:config.status},{status:202});
  const result=await config.json();const configuration=JSON.parse(atob(result.configFileContents));
  if(configuration.project_info?.project_id!=='fletya'||!configuration.client?.some((c:{client_info?:{android_client_info?:{package_name?:string}}})=>c.client_info?.android_client_info?.package_name==='app.fletya.client'))return Response.json({status:'configuration_mismatch'},{status:502});
  return Response.json({status:'ready',configuration});
 }catch{return Response.json({status:'setup_unavailable'},{status:503});}
});
