const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(path.join(__dirname, '../../index.html'), 'utf8');
const scripts = [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/g)].map(match => match[1]);
const application = scripts.find(script => script.includes('const state='));

function runtime(responses = []) {
  const intervals = new Map();
  const clearedWatches = [];
  const queries = [];
  const messages = [];
  const nodes = new Map();
  let timerId = 0;
  let signOuts = 0;
  function element(id) {
    const classes = new Set(id === 'client' ? ['hidden'] : []);
    return {
      value: id === 'vehicle' ? 'pickup' : id === 'km' ? '8' : '0',
      style: {}, innerHTML: '', textContent: '', children: [],
      classList: {
        contains: name => classes.has(name),
        toggle(name, enabled) { if (enabled) classes.add(name); else classes.delete(name); }
      },
      appendChild(child) { this.children.push(child); },
      scrollIntoView() {}
    };
  }
  const document = {
    getElementById(id) { if (!nodes.has(id)) nodes.set(id, element(id)); return nodes.get(id); },
    createElement: () => element('')
  };
  const api = {
    auth: {
      async getUser() { return { data: { user: { id: 'driver-1' } } }; },
      async signOut() { signOuts++; }
    },
    from(table) {
      const entry = { table, calls: [] };
      queries.push(entry);
      const result = responses.shift();
      assert.ok(result, 'Unexpected database call: ' + table);
      const builder = {};
      for (const method of ['select', 'eq', 'in', 'is', 'order', 'limit', 'update']) {
        builder[method] = (...args) => { entry.calls.push([method, ...args]); return builder; };
      }
      builder.single = builder.maybeSingle = async () => result;
      builder.then = (resolve, reject) => Promise.resolve(result).then(resolve, reject);
      return builder;
    }
  };
  const map = { setView() { return this; } };
  const context = vm.createContext({
    document, console: { error() {}, warn() {}, log() {} }, supabaseClient: api,
    navigator: { geolocation: { clearWatch(id) { clearedWatches.push(id); } } },
    localStorage: { getItem() { return null; } },
    L: { map() { return map; }, tileLayer() { return { addTo() {} }; } },
    setInterval(callback) { intervals.set(++timerId, callback); return timerId; },
    clearInterval(id) { intervals.delete(id); }, setTimeout() {},
    recordMessage(message) { messages.push(message); }
  });
  vm.runInContext(application, context);
  vm.runInContext('toast = recordMessage', context);
  return { context, intervals, clearedWatches, queries, messages, document, api,
    run: code => vm.runInContext(code, context), get signOuts() { return signOuts; } };
}

test('all inline JavaScript parses after conflict resolution', () => {
  for (const source of scripts) new vm.Script(source);
});

test('completion uses the database job despite stale local state and stops GPS', async () => {
  const r = runtime([{ data: { id: 'live-job', status: 'en_route' } },
    { data: { id: 'live-job', status: 'completed' } }]);
  r.run("state.active={id:'stale-job'}; state.accepted=true; fletyaGpsWatch=0; renderDriver=async()=>{};");
  await r.run('completeDriver()');
  assert.equal(r.run('state.active'), null);
  assert.equal(r.run('state.accepted'), false);
  assert.deepEqual(r.clearedWatches, [0]);
  const filters = r.queries[1].calls.filter(call => call[0] === 'eq');
  assert.deepEqual(filters, [['eq', 'id', 'live-job'], ['eq', 'driver_id', 'driver-1'], ['eq', 'status', 'en_route']]);
  assert.ok(r.messages.some(message => message.includes('completado correctamente')));
});

test('zero-row completion reports failure rather than a false success', async () => {
  const r = runtime([{ data: { id: 'live-job', status: 'en_route' } }, { data: null }]);
  r.run('refreshes=0; renderDriver=async()=>{refreshes++}; fletyaGpsWatch=7;');
  await r.run('completeDriver()');
  assert.equal(r.run('refreshes'), 1);
  assert.deepEqual(r.clearedWatches, []);
  assert.ok(r.messages.some(message => message.includes('No se pudo completar:')));
  assert.ok(!r.messages.some(message => message.includes('completado correctamente')));
});

test('lookup error cannot complete a stale local job', async () => {
  const r = runtime([{ error: { message: 'lookup failed' } }]);
  r.run("state.active={id:'stale-job'}");
  await r.run('completeDriver()');
  assert.equal(r.queries.length, 1);
  assert.ok(r.messages.some(message => message.includes('lookup failed')));
});

test('driver refresh has one timer and rejects overlapping ticks', async () => {
  const r = runtime();
  r.run("renderDriver=async()=>new Promise(resolve=>{finishRefresh=resolve}); startDriverPanelRefresh('driver-1'); startDriverPanelRefresh('driver-1');");
  assert.equal(r.intervals.size, 2); // One existing client timer and one driver timer.
  const tick = [...r.intervals.values()][1];
  let renders = 0;
  r.context.countRender = () => renders++;
  r.run('renderDriver=async()=>{countRender(); await new Promise(resolve=>{finishRefresh=resolve})}');
  const first = tick();
  await new Promise(setImmediate);
  await tick();
  assert.equal(renders, 1);
  r.run('finishRefresh()');
  await first;
  assert.equal(r.run('driverPanelRefreshBusy'), false);
});

test('driver refresh ignores hidden panels and a changed authenticated user', async () => {
  const r = runtime();
  r.run("renders=0; renderDriver=async()=>{renders++}; startDriverPanelRefresh('driver-1')");
  const tick = [...r.intervals.values()][1];
  r.document.getElementById('driver').classList.toggle('hidden', true);
  await tick();
  r.document.getElementById('driver').classList.toggle('hidden', false);
  r.api.auth.getUser = async () => ({ data: { user: { id: 'other-driver' } } });
  await tick();
  assert.equal(r.run('renders'), 0);
});

test('global client timer no longer duplicates driver polling', async () => {
  const r = runtime();
  r.run('renders=0; renderDriver=async()=>{renders++}');
  await [...r.intervals.values()][0]();
  assert.equal(r.run('renders'), 0);
});

test('logout clears both the GPS watch and driver panel timer', async () => {
  const r = runtime();
  r.run("show=()=>{}; fletyaGpsWatch=3; startDriverPanelRefresh('driver-1')");
  await r.run('logoutDriver()');
  assert.deepEqual(r.clearedWatches, [3]);
  assert.equal(r.intervals.size, 1);
  assert.equal(r.run('driverPanelRefreshUserId'), null);
  assert.equal(r.signOuts, 1);
});

test('render restores the active job, keeps history and starts automatic GPS', async () => {
  const r = runtime([
    { data: { role: 'driver', full_name: 'Driver' } },
    { data: { id: 'live-job', status: 'en_route', price: 100, origin: 'A', destination: 'B' } },
    { data: [{ id: 'old-job', status: 'completed', price: 50, origin: 'History A', destination: 'History B' }] },
    { data: [] }
  ]);
  r.run('startDriverNotifications=()=>{}; syncFletyaGps=async(user,job)=>{restoredGps=job.id}');
  await r.run('renderDriver()');
  assert.equal(r.run('state.active.id'), 'live-job');
  assert.equal(r.run('state.accepted'), true);
  assert.equal(r.run('restoredGps'), 'live-job');
  assert.match(r.document.getElementById('jobCard').innerHTML, /History A/);
  assert.equal(r.intervals.size, 2);
});
