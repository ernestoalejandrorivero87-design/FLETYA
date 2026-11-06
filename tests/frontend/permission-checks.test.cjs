const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const html = fs.readFileSync(path.join(__dirname, '../../index.html'), 'utf8');
const script = [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/g)]
  .map(match => match[1]).find(source => source.includes('const permissionTestAccounts'));
function runtime() {
  const context = vm.createContext({ supabaseClient: null, IS_FLETYA_PRODUCTION_HOST: false,
    SUPABASE_URL: 'https://ccdtpwvalqznasstnqxj.supabase.co' });
  vm.runInContext(script, context);
  return code => vm.runInContext(code, context);
}
test('HTTP permission results do not treat network or unexpected server errors as a pass', () => {
  const run = runtime();
  for (const code of ['PGRST301', 'P0001', '500', undefined]) {
    assert.equal(run(`deniedPermissionResponse(${JSON.stringify({ error: { code } })})`), false);
  }
  assert.equal(run("deniedPermissionResponse({error:{code:'42501'}})"), true);
  assert.equal(run('deniedPermissionResponse({data:[]})'), true);
  assert.equal(run("deniedPermissionResponse({data:[{id:'changed-row'}]})"), false);
  assert.equal(run('deniedPermissionResponse({data:null})'), false);
});
test('permission diagnostics are disabled for production host and non-testing backends', () => {
  const run = runtime();
  assert.equal(run('permissionCheckEnvironment()'), true);
  assert.equal(run('IS_FLETYA_PRODUCTION_HOST=true; permissionCheckEnvironment()'), false);
  assert.equal(run("IS_FLETYA_PRODUCTION_HOST=false; SUPABASE_URL='https://other.supabase.co'; permissionCheckEnvironment()"), false);
});
