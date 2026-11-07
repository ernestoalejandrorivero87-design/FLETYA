// CI-only: two real PostgreSQL connections compete for the same requested row.
import { spawn, execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';
if (process.env.PGDATABASE !== 'fletya_test') throw new Error('Run only against the disposable fletya_test database');
const args = ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1'];
const client = '10000000-0000-0000-0000-000000000001';
const driver = '20000000-0000-0000-0000-000000000002';
const query = sql => execFileSync('psql', args, { input: sql, encoding: 'utf8' }).trim();
function competingQuery(sql) {
  return new Promise((resolve, reject) => {
    const proc = spawn('psql', args);
    let stdout = '', stderr = '';
    proc.stdout.on('data', data => { stdout += data; });
    proc.stderr.on('data', data => { stderr += data; });
    proc.on('error', reject);
    proc.on('close', code => code === 0 ? resolve(stdout) : reject(new Error(stderr)));
    proc.stdin.end(sql);
  });
}
for (const first of ['client', 'driver']) {
  const id = randomUUID();
  query(`select set_config('request.jwt.claim.role','service_role',false);
    insert into public.jobs(id,origin,destination,price,status,client_id)
    values ('${id}','Race origin','Race destination',100,'requested','${client}');`);
  const claim = role => `begin; set local statement_timeout='8s'; set local role authenticated;
    select set_config('request.jwt.claim.role','authenticated',true);
    select set_config('request.jwt.claim.sub','${role === 'client' ? client : driver}',true);
    with changed as (update public.jobs set ${role === 'client' ? "status='cancelled'" : "status='en_route',driver_id=auth.uid()"}
      where id='${id}' and status='requested' and driver_id is null ${role === 'client' ? 'and client_id=auth.uid()' : ''}
      returning status) select 'CHANGED:'||status from changed;
    select pg_sleep(0.25); commit;`;
  const contender1 = competingQuery(claim(first));
  await new Promise(resolve => setTimeout(resolve, 30));
  const contender2 = competingQuery(claim(first === 'client' ? 'driver' : 'client'));
  const output = (await Promise.all([contender1, contender2])).join('\n');
  const changes = output.match(/CHANGED:(cancelled|en_route)/g) || [];
  assert.equal(changes.length, 1, 'Only cancellation or acceptance may win');
  const row = JSON.parse(query(`select json_build_object('status',status,'driver_id',driver_id) from public.jobs where id='${id}'`));
  assert.ok(['cancelled', 'en_route'].includes(row.status));
  assert.equal(row.driver_id, row.status === 'en_route' ? driver : null);
  console.log(`Concurrent cancellation/acceptance (${first} launched first): one winner, final state ${row.status}`);
}
