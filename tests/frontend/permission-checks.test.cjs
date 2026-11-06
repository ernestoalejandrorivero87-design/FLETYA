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
  const run = code => vm.runInContext(code, context);
  run.context = context;
  return run;
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
test('cross-account HTTP cases target the opposite pair and preserve assignment', () => {
  const run = runtime();
  for (const actor of ['clientA', 'driverA', 'clientB', 'driverB']) {
    const oppositePair = actor.endsWith('A') ? 'B' : 'A';
    const targets = JSON.parse(run(`JSON.stringify(crossAccountPermissionTargets('${actor}'))`));
    assert.deepEqual(targets.map(target => target.table), ['jobs', 'driver_locations']);
    for (const target of targets) {
      assert.equal(target.driverId, run(`permissionTestAccounts.driver${oppositePair}`));
      assert.match(target.id, /^[\da-f-]{36}$/);
    }
  }
});
function gpsApi(results) {
  return { from() {
    const result = results.shift();
    assert.ok(result, 'Unexpected GPS probe query');
    const query = {};
    for (const method of ['select', 'eq', 'update', 'insert']) query[method] = () => query;
    query.maybeSingle = async () => result;
    query.then = (resolve, reject) => Promise.resolve(result).then(resolve, reject);
    return query;
  } };
}
const gps = { id: 'location', driver_id: 'driver', job_id: 'job', latitude: 21,
  longitude: -86, accuracy: 10, updated_at: '2026-11-06T15:10:27Z' };
test('completed GPS probes require policy denial and unchanged historical data', async () => {
  const run = runtime();
  run.context.api = gpsApi([
    { data: { status: 'completed' } }, { data: gps },
    { error: { code: '42501' } }, { error: { code: '42501' } }, { data: { ...gps } }
  ]);
  const result = await run("checkCompletedGps(api,'driverA','driver')");
  assert.equal(result.length, 3);
  assert.ok(result.every(check => check.passed));
});
test('a duplicate key does not prove that completed GPS INSERT is protected', async () => {
  const run = runtime();
  run.context.api = gpsApi([
    { data: { status: 'completed' } }, { data: gps },
    { data: [{ id: gps.id }] }, { error: { code: '23505' } },
    { data: { ...gps, updated_at: 'changed' } }
  ]);
  const result = await run("checkCompletedGps(api,'driverA','driver')");
  assert.ok(result.every(check => check.passed === false));
});
test('completed GPS cases are skipped on active jobs and fail on missing fixtures', async () => {
  const run = runtime();
  run.context.api = gpsApi([{ data: { status: 'en_route' } }]);
  assert.equal(await run("checkCompletedGps(api,'driverB','driver')"), null);
  run.context.api = gpsApi([{ data: { status: 'completed' } }, { data: null }]);
  await assert.rejects(run("checkCompletedGps(api,'driverA','driver')"), /histórico/);
});
