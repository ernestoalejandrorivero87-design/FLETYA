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
      style: {}, innerHTML: '', textContent: '', children: [], attributes: {},
      setAttribute(name,value) { this.attributes[name]=value; },
      removeAttribute(name) { delete this.attributes[name]; },
      classList: {
        contains: name => classes.has(name),
        add(name) { classes.add(name); },
        remove(name) { classes.delete(name); },
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
  const map = {
    center: { lat: 21.1619, lng: -86.8515 }, events: {},
    setView(point) { this.center = Array.isArray(point) ? {lat:point[0],lng:point[1]} : point; return this; },
    getCenter() { return this.center; }, on(event, handler) { this.events[event]=handler; return this; },
    removeLayer() {}, fitBounds() {}, invalidateSize() {}
  };
  function marker(point, options = {}) {
    return { point: Array.isArray(point) ? { lat: point[0], lng: point[1] } : point, options, events: {},
      addTo() { return this; }, bindPopup() { return this; },
      getLatLng() { return this.point; },
      setLatLng(value) { this.point = Array.isArray(value) ? {lat:value[0],lng:value[1]} : value; return this; },
      on(event,handler) { this.events[event]=handler; return this; }
    };
  }
  const context = vm.createContext({
    document, console: { error() {}, warn() {}, log() {} }, supabaseClient: api,
    navigator: { geolocation: { clearWatch(id) { clearedWatches.push(id); } } },
    localStorage: { getItem() { return null; } },
    L: { map() { return map; }, marker, polyline() { return { addTo() {return this;}, getBounds() {return [];} }; }, tileLayer() { return { addTo() {} }; } },
    setInterval(callback) { intervals.set(++timerId, callback); return timerId; },
    clearInterval(id) { intervals.delete(id); }, setTimeout() {},
    recordMessage(message) { messages.push(message); }
  });
  vm.runInContext(application, context);
  const authScript = scripts.find(script => script.includes('async function logoutClient()'));
  vm.runInContext(authScript.slice(authScript.indexOf('function setClientSessionIdentity')).replace("showAccess('client');\nrestoreRoleSession();", ''), context);
  vm.runInContext('toast = recordMessage', context);
  return { context, intervals, clearedWatches, queries, messages, document, api,
    run: code => vm.runInContext(code, context), get signOuts() { return signOuts; } };
}

test('all inline JavaScript parses after conflict resolution', () => {
  for (const source of scripts) new vm.Script(source);
});

test('client polling preserves draft addresses and quoted route before the first job', async () => {
  const noJobs = () => [
    { data: { role: 'client' } }, { data: { full_name: 'Cliente A' } },
    { data: [] }, { data: [] }
  ];
  const r = runtime([...noJobs(), ...noJobs(), ...noJobs()]);
  r.run('setClientSessionIdentity=()=>{}; routeClears=0; clearRouteOnMap=()=>{routeClears++};');
  r.document.getElementById('client').classList.toggle('hidden', false);
  const poll = [...r.intervals.values()][0];
  r.document.getElementById('origin').value = 'Plaza Las Américas';
  r.document.getElementById('dest').value = '';
  poll();
  // Drain the asynchronous auth/profile/jobs/history chain started by the timer.
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(r.document.getElementById('origin').value, 'Plaza Las Américas');
  r.document.getElementById('dest').value = 'Región 102';
  r.document.getElementById('km').value = '12.5';
  r.document.getElementById('routeInfo').textContent = 'Ruta calculada';
  r.run('quote()');
  const price = r.document.getElementById('price').textContent;
  for (let i = 0; i < 2; i++) {
    poll();
    await new Promise(resolve => setImmediate(resolve));
  }
  assert.equal(r.document.getElementById('origin').value, 'Plaza Las Américas');
  assert.equal(r.document.getElementById('dest').value, 'Región 102');
  assert.equal(r.document.getElementById('km').value, '12.5');
  assert.equal(r.document.getElementById('price').textContent, price);
  assert.equal(r.document.getElementById('routeInfo').textContent, 'Ruta calculada');
  assert.equal(r.run('routeClears'), 0);
  assert.equal(r.run('state.active'), null);
});

test('losing an active client job still clears its route and stops tracking', async () => {
  const r = runtime([
    { data: { role: 'client' } }, { data: {} }, { data: [] }, { data: [] }
  ]);
  r.run("setClientSessionIdentity=()=>{}; routeClears=0; clearRouteOnMap=()=>{routeClears++}; state.active={id:'old-job',status:'en_route'}; driverTrackingTimer=setInterval(()=>{},5000);");
  await r.run('renderClient()');
  assert.equal(r.run('routeClears'), 1);
  assert.equal(r.run('driverTrackingTimer'), null);
  assert.equal(r.document.getElementById('driverTracking').hidden, true);
  assert.equal(r.run('state.active'), null);
});

test('acceptance requires an unassigned requested row and a returned assignment', async () => {
  const accepted = { id: 'requested-job', status: 'en_route', driver_id: 'driver-1', price: 100 };
  const r = runtime([{ data: accepted }]);
  r.run("state.active={id:'requested-job',status:'requested'}; state.jobs=[{id:'requested-job'}]; renderDriver=async()=>{};");
  await r.run('acceptDriver()');
  assert.equal(r.run('state.active.id'), 'requested-job');
  assert.equal(r.run('state.active.status'), 'en_route');
  assert.equal(r.run('state.accepted'), true);
  assert.equal(r.run('state.jobs.length'), 0);
  assert.deepEqual(r.queries[0].calls.filter(call => ['eq', 'is'].includes(call[0])),
    [['eq', 'id', 'requested-job'], ['eq', 'status', 'requested'], ['is', 'driver_id', null]]);
  assert.ok(r.messages.includes('Servicio aceptado correctamente.'));
});

test('losing an acceptance race refreshes availability without claiming success', async () => {
  const r = runtime([{ data: null }]);
  r.run("refreshes=0; state.active={id:'requested-job',status:'requested'}; state.accepted=false; renderDriver=async()=>{refreshes++};");
  await r.run('acceptDriver()');
  assert.equal(r.run('state.active.status'), 'requested');
  assert.equal(r.run('state.accepted'), false);
  assert.equal(r.run('refreshes'), 1);
  assert.ok(r.messages.some(message => message.includes('ya no está disponible')));
  assert.ok(!r.messages.some(message => message.includes('aceptado correctamente')));
});

test('acceptance permission errors do not mutate local assignment', async () => {
  const r = runtime([{ error: { message: 'permission denied' } }]);
  r.run("state.active={id:'requested-job',status:'requested'}; state.accepted=false;");
  await r.run('acceptDriver()');
  assert.equal(r.run('state.active.status'), 'requested');
  assert.equal(r.run('state.accepted'), false);
  assert.ok(r.messages.some(message => message.includes('permission denied')));
});

test('acceptance captures the selected job before awaiting authentication', async () => {
  const r = runtime([{ data: { id: 'first-job', status: 'en_route', driver_id: 'driver-1' } }]);
  let resumeAuth;
  r.api.auth.getUser = () => new Promise(resolve => { resumeAuth = resolve; });
  r.run("state.active={id:'first-job',status:'requested'}; renderDriver=async()=>{};");
  const pending = r.run('acceptDriver()');
  r.run("state.active={id:'another-job',status:'requested'};");
  resumeAuth({ data: { user: { id: 'driver-1' } } });
  await pending;
  assert.ok(r.queries[0].calls.some(call => call[0] === 'eq' && call[1] === 'id' && call[2] === 'first-job'));
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


test('all logout buttons use local scope and clear identity and private views', async () => {
  for (const action of ['logoutClient', 'logoutDriver', 'logoutAdmin']) {
    const r = runtime();
    r.run("setClientSessionIdentity=()=>{document.getElementById('clientSessionIdentity').textContent=''};");
    let options;
    r.api.auth.signOut = async value => { options = value; return { error: null }; };
    r.document.getElementById('clientSessionIdentity').textContent = 'Sesión activa';
    r.document.getElementById('clientHistory').textContent = 'Private history';
    r.run("state.active={id:'private-job'}; state.jobs=[state.active];");
    await r.run(action + '()');
    assert.equal(options.scope, 'local');
    assert.equal(r.run('state.active'), null);
    assert.equal(r.run('state.jobs.length'), 0);
    assert.equal(r.document.getElementById('clientLogoutBtn').style.display, 'none');
    assert.equal(r.document.getElementById('clientSessionIdentity').textContent, '');
    assert.equal(r.document.getElementById('clientHistory').textContent, 'Inicia sesión para ver tu historial.');
  }
});

test('failed logout does not claim success and can be retried', async () => {
  const r = runtime();
  r.api.auth.signOut = async () => ({ error: new Error('storage unavailable') });
  await r.run('logoutClient()');
  assert.ok(!r.messages.includes('Sesión cerrada'));
  assert.match(r.document.getElementById('authMessage').textContent, /No se pudo cerrar/);
  assert.equal(r.run('logoutPending'), false);
});

test('local SIGNED_OUT clears the screen before a slow revocation finishes', async () => {
  const r = runtime();
  r.run('setClientSessionIdentity=()=>{}');
  let finish;
  r.api.auth.signOut = () => {
    r.run('clearSignedOutView()');
    return new Promise(resolve => { finish = resolve; });
  };
  const closing = r.run('logoutClient()');
  assert.equal(r.document.getElementById('clientLogoutBtn').style.display, 'none');
  assert.equal(r.run('state.active'), null);
  // A second tap must not start a second signout.
  await r.run('logoutClient()');
  finish({ error: new Error('network offline') });
  await closing;
  assert.ok(r.messages.includes('Sesión cerrada'));
  assert.match(r.document.getElementById('authMessage').textContent, /No se pudo confirmar/);
});

test('a client poll started before logout cannot restore the old session', async () => {
  const r = runtime();
  r.run('setClientSessionIdentity=()=>{}');
  let finishAuth;
  r.api.auth.getUser = () => new Promise(resolve => { finishAuth = resolve; });
  const pending = r.run('renderClient()');
  r.run('clearSignedOutView()');
  finishAuth({ data: { user: { id: 'previous-client' } } });
  await pending;
  assert.equal(r.queries.length, 0);
  assert.equal(r.run('state.active'), null);
  assert.equal(r.document.getElementById('clientLogoutBtn').style.display, 'none');
});


const paymentJob = { id: 'payment-job', origin: 'Plaza las Américas', destination: 'Playa del Carmen',
  price: 2420.90, driver_id: 'driver-1', status: 'completed', driver_paid: false };
function paymentRuntime(responses, confirmed = true) {
  const r = runtime(responses);
  r.context.window = { confirm: message => { r.confirmations.push(message); return confirmed; } };
  r.confirmations = [];
  r.run("currentJobDetailsId='payment-job'; adminRefreshes=0; detailRefreshes=0; renderAdmin=async()=>{adminRefreshes++}; viewJob=async()=>{detailRefreshes++};");
  return r;
}

test('payment confirmation shows exact cents and updates only the selected unpaid completed job', async () => {
  const r = paymentRuntime([{ data: { role: 'admin' } }, { data: paymentJob },
    { data: { id: paymentJob.id, driver_paid: true } }]);
  await r.run("markJobPaid('payment-job')");
  assert.equal(r.confirmations.length, 1);
  assert.match(r.confirmations[0], /2,057\.76/);
  assert.match(r.confirmations[0], /363\.14/);
  assert.match(r.confirmations[0], /no transfiere dinero/);
  const update = r.queries.find(q => q.calls.some(c => c[0] === 'update'));
  assert.deepEqual(update.calls.filter(c => c[0] === 'eq'), [
    ['eq', 'id', paymentJob.id], ['eq', 'driver_id', 'driver-1'], ['eq', 'price', 2420.9],
    ['eq', 'status', 'completed'], ['eq', 'driver_paid', false]
  ]);
  assert.equal(update.calls.find(c => c[0] === 'update')[1].driver_paid, true);
  assert.equal(r.run('adminRefreshes'), 1);
  assert.equal(r.run('detailRefreshes'), 1);
  assert.ok(r.messages.includes('Pago registrado para este servicio.'));
});

test('cancelling payment confirmation sends no update', async () => {
  const r = paymentRuntime([{ data: { role: 'admin' } }, { data: paymentJob }], false);
  await r.run("markJobPaid('payment-job')");
  assert.equal(r.queries.length, 2);
  assert.equal(r.run('adminRefreshes'), 0);
  assert.ok(!r.messages.includes('Pago registrado para este servicio.'));
});

test('clients and drivers cannot register payments through the handler', async () => {
  for (const role of ['client', 'driver']) {
    const r = paymentRuntime([{ data: { role } }]);
    await r.run("markJobPaid('payment-job')");
    assert.equal(r.queries.length, 1);
    assert.equal(r.confirmations.length, 0);
    assert.ok(r.messages.includes('Esta acción es solo para administradores'));
  }
});

test('already paid, active, unassigned and invalid-price jobs cannot be marked paid', async () => {
  for (const patch of [{ driver_paid: true }, { status: 'en_route' }, { driver_id: null },
    { price: null }, { price: -1 }, { price: 'invalid' }]) {
    const r = paymentRuntime([{ data: { role: 'admin' } }, { data: { ...paymentJob, ...patch } }]);
    await r.run("markJobPaid('payment-job')");
    assert.equal(r.queries.length, 2);
    assert.equal(r.confirmations.length, 0);
  }
});

test('zero-row and failed payment updates cannot claim success', async () => {
  for (const response of [{ data: null }, { data: null, error: { message: 'denied' } }]) {
    const r = paymentRuntime([{ data: { role: 'admin' } }, { data: paymentJob }, response]);
    await r.run("markJobPaid('payment-job')");
    assert.ok(!r.messages.includes('Pago registrado para este servicio.'));
    assert.equal(r.run('adminRefreshes'), 0);
    assert.equal(r.run('paymentJobsInFlight.size'), 0);
  }
});

test('double tap starts just one payment operation', async () => {
  const r = paymentRuntime([{ data: { role: 'admin' } }, { data: paymentJob }], false);
  let finish;
  r.api.auth.getUser = () => new Promise(resolve => { finish = resolve; });
  const pending = r.run("markJobPaid('payment-job')");
  await r.run("markJobPaid('payment-job')");
  finish({ data: { user: { id: 'admin-1' } } });
  await pending;
  assert.equal(r.confirmations.length, 1);
  assert.equal(r.run('paymentJobsInFlight.size'), 0);
});

test('closing details while payment validation is pending prevents confirmation and mutation', async () => {
  const r = paymentRuntime([]);
  let finish;
  r.api.auth.getUser = () => new Promise(resolve => { finish = resolve; });
  const pending = r.run("markJobPaid('payment-job')");
  r.run('closeJobModal()');
  finish({ data: { user: { id: 'admin-1' } } });
  await pending;
  assert.equal(r.confirmations.length, 0);
  assert.equal(r.queries.length, 0);
});

test('details show pending or registered payment and only eligible jobs have an action', async () => {
  for (const patch of [{}, { driver_paid: true }, { status: 'en_route' }]) {
    const job = { ...paymentJob, ...patch };
    const r = runtime([{ data: job }, { data: [] }]);
    await r.run("viewJob('payment-job')");
    const box = r.document.getElementById('jobModalContent').children[0];
    assert.match(box.children[0].textContent, job.driver_paid ? /Registrado/ : /Pendiente/);
    assert.match(box.children[1].textContent, /2,057\.76/);
    const action = box.children.find(child => child.textContent === 'Registrar pago de este servicio');
    assert.equal(Boolean(action), job.status === 'completed' && !job.driver_paid);
  }
  assert.doesNotMatch(html, /markDriverPaid/);
});

test('net plus commission always matches the service total in cents', () => {
  const r = runtime();
  for (const price of [2420.9, 0.03, 959.5, 411.2]) {
    const amounts = r.run('driverPaymentFor({price:' + price + '})');
    assert.equal(Math.round(amounts.net * 100) + Math.round(amounts.commission * 100), Math.round(price * 100));
  }
});


test('guest role navigation shows exactly one access form and no service panels', async () => {
  const r = runtime();
  r.api.auth.getUser = async () => ({ data: { user: null } });
  for (const role of ['client', 'driver', 'admin']) {
    await r.run("navigateToRole('" + role + "')");
    for (const [key, id] of Object.entries({ client: 'authClient', driver: 'authDriver', admin: 'authAdmin' })) {
      assert.equal(r.document.getElementById(id).classList.contains('hidden'), key !== role);
      assert.equal(r.document.getElementById(key).classList.contains('hidden'), true);
    }
    assert.equal(r.document.getElementById('access').classList.contains('hidden'), false);
    assert.equal(r.document.getElementById('nav-' + role).attributes['aria-current'], 'page');
  }
});

test('switching to another role preserves the signed-in account and visible panel', async () => {
  const r = runtime([{ data: { role: 'driver', full_name: 'Fletero' } }]);
  r.run("activeSessionRole='driver'; show('client'); document.getElementById('client').classList.add('hidden'); document.getElementById('driver').classList.remove('hidden');");
  await r.run("navigateToRole('admin')");
  assert.equal(r.signOuts, 0);
  assert.equal(r.run('activeSessionRole'), 'driver');
  assert.equal(r.document.getElementById('driver').classList.contains('hidden'), false);
  assert.equal(r.document.getElementById('admin').classList.contains('hidden'), true);
  assert.match(r.messages.at(-1), /Cierra sesión/);
});

test('login opens only the database-validated role and clears passwords', async () => {
  const ids = { client: ['authEmail', 'authPassword'], driver: ['driverEmail', 'driverPassword'], admin: ['adminEmail', 'adminPassword'] };
  for (const role of Object.keys(ids)) {
    const r = runtime([{ data: { role, full_name: 'Ernesto' } }]);
    r.run('renderClient=async()=>{}; renderDriver=async()=>{}; renderAdmin=async()=>{};');
    r.document.getElementById(ids[role][0]).value = role + '@example.com';
    r.document.getElementById(ids[role][1]).value = 'synthetic-password';
    r.api.auth.signInWithPassword = async () => ({ data: { user: { id: 'verified-user' } } });
    await r.run("loginForRole('" + role + "')");
    assert.equal(r.run('activeSessionRole'), role);
    assert.equal(r.document.getElementById('access').classList.contains('hidden'), true);
    assert.equal(r.document.getElementById('sessionBar').classList.contains('hidden'), false);
    for (const key of Object.keys(ids)) {
      assert.equal(r.document.getElementById(key).classList.contains('hidden'), key !== role);
      assert.equal(r.document.getElementById(ids[key][1]).value, '');
    }
  }
});

test('login with a mismatched role signs out locally and keeps the expected access form', async () => {
  const r = runtime([{ data: { role: 'driver' } }]);
  r.api.auth.signInWithPassword = async () => ({ data: { user: { id: 'driver-1' } } });
  let scope;
  r.api.auth.signOut = async options => { scope = options.scope; return { error: null }; };
  r.document.getElementById('authEmail').value = 'driver@example.com';
  r.document.getElementById('authPassword').value = 'synthetic-password';
  await r.run("loginClient()");
  assert.equal(scope, 'local');
  assert.equal(r.run('activeSessionRole'), null);
  assert.equal(r.document.getElementById('authClient').classList.contains('hidden'), false);
  assert.equal(r.document.getElementById('driver').classList.contains('hidden'), true);
});

test('reloading restores all three roles from the profile, without signing in again', async () => {
  for (const role of ['client', 'driver', 'admin']) {
    const r = runtime([{ data: { role, full_name: 'Ernesto' } }]);
    r.run('renderClient=async()=>{}; renderDriver=async()=>{}; renderAdmin=async()=>{};');
    await r.run('restoreRoleSession()');
    assert.equal(r.run('activeSessionRole'), role);
    assert.equal(r.document.getElementById(role).classList.contains('hidden'), false);
    assert.equal(r.document.getElementById('access').classList.contains('hidden'), true);
    assert.equal(r.signOuts, 0);
  }
});

test('signout returns to the client access form and hides all private panels', async () => {
  const r = runtime();
  r.run("activeSessionRole='admin'; clearSignedOutView()");
  assert.equal(r.run('activeSessionRole'), null);
  assert.equal(r.document.getElementById('access').classList.contains('hidden'), false);
  for (const role of ['client', 'driver', 'admin']) {
    assert.equal(r.document.getElementById(role).classList.contains('hidden'), true);
  }
  assert.equal(r.document.getElementById('sessionBar').classList.contains('hidden'), true);
});

test('a delayed role restore cannot reopen a panel after signout', async () => {
  const r = runtime();
  let finish;
  r.api.auth.getUser = () => new Promise(resolve => { finish = resolve; });
  const pending = r.run('restoreRoleSession()');
  r.run('clearSignedOutView()');
  finish({ data: { user: { id: 'old-user' } } });
  await pending;
  assert.equal(r.run('activeSessionRole'), null);
  assert.equal(r.queries.length, 0);
});

test('stale driver and admin renders stop after signout', async () => {
  for (const fn of ['renderDriver', 'renderAdmin']) {
    const r = runtime();
    let finish;
    r.api.auth.getUser = () => new Promise(resolve => { finish = resolve; });
    const pending = r.run(fn + '()');
    r.run('clearSignedOutView()');
    finish({ data: { user: { id: 'old-user' } } });
    await pending;
    assert.equal(r.queries.length, 0);
    assert.equal(r.run('activeSessionRole'), null);
  }
});


test('coordinates stay exact while written addresses retain the local context', () => {
  const r = runtime();
  assert.equal(r.run("prepareRouteAddress('21.161900, -86.851500')"), '21.161900, -86.851500');
  assert.equal(r.run("prepareRouteAddress('Plaza Las Américas')"), 'Plaza Las Américas, Cancún, Quintana Roo, México');
  assert.equal(r.run("parseRouteCoordinates('91, -86')"), null);
});

test('cancelled map selection preserves draft fields and quote', () => {
  const r = runtime();
  r.run("activeSessionRole='client'");
  r.document.getElementById('origin').value = '21.1, -86.8';
  r.document.getElementById('dest').value = 'Original destination';
  r.document.getElementById('price').textContent = '$400';
  r.run("openLocationPicker('origin'); locationPickerMarker.setLatLng({lat:21.2,lng:-86.9}); closeLocationPicker();");
  assert.equal(r.document.getElementById('origin').value, '21.1, -86.8');
  assert.equal(r.document.getElementById('dest').value, 'Original destination');
  assert.equal(r.document.getElementById('price').textContent, '$400');
});

test('confirming a draggable map pin changes only the chosen endpoint and recalculates', async () => {
  const r = runtime();
  r.run("activeSessionRole='client'");
  r.document.getElementById('origin').value = 'Plaza Las Américas';
  let body;
  r.api.functions = { invoke: async (name, options) => { body=options.body; return {data:{distance_km:8.22,duration_text:'22 min'}}; } };
  r.run("openLocationPicker('dest'); locationPickerMarker.setLatLng({lat:21.16,lng:-86.88}); locationPickerMarker.events.dragend();");
  assert.equal(r.run('locationPickerMarker.options.draggable'), true);
  await r.run('confirmLocationPicker()');
  assert.equal(r.document.getElementById('dest').value, '21.160000, -86.880000');
  assert.equal(r.document.getElementById('origin').value, 'Plaza Las Américas');
  assert.equal(body.destination, '21.160000, -86.880000');
  assert.equal(r.document.getElementById('km').value, 8.22);
  assert.equal(r.document.getElementById('locationPickerModal').classList.contains('hidden'), true);
});

test('GPS runs only on explicit request, handles denied permission and preserves typed locations', async () => {
  const r = runtime();
  let requests=0;
  r.context.navigator.geolocation.getCurrentPosition = (ok, fail) => { requests++; fail({code:1}); };
  r.run("activeSessionRole='client'");
  r.document.getElementById('origin').value = 'Written origin';
  assert.equal(requests, 0);
  await r.run("useClientLocation('origin')");
  assert.equal(requests, 1);
  assert.equal(r.document.getElementById('origin').value, 'Written origin');
  assert.match(r.document.getElementById('locationFeedback').textContent, /denegado/);
  assert.equal(r.document.getElementById('originGpsBtn').disabled, false);
});

test('GPS selects one exact point without using a continuous location watch', async () => {
  const r = runtime();
  r.run("activeSessionRole='client'");
  r.document.getElementById('dest').value = '';
  r.context.navigator.geolocation.getCurrentPosition = ok => ok({coords:{latitude:21.1619,longitude:-86.8515,accuracy:12}});
  await r.run("useClientLocation('origin')");
  assert.equal(r.document.getElementById('origin').value, '21.161900, -86.851500');
  assert.equal(r.document.getElementById('dest').value, '');
  assert.equal(r.run('fletyaGpsWatch'), null);
  assert.match(r.document.getElementById('locationFeedback').textContent, /12 m/);
});

test('late GPS cannot replace an address edited while location was pending', async () => {
  const r = runtime();
  r.run("activeSessionRole='client'");
  let finish;
  r.context.navigator.geolocation.getCurrentPosition = ok => { finish=ok; };
  const pending=r.run("useClientLocation('origin')");
  r.document.getElementById('origin').value='A more recent address';
  r.run("routeInputChanged('origin')");
  finish({coords:{latitude:21.1,longitude:-86.8,accuracy:10}});
  await pending;
  assert.equal(r.document.getElementById('origin').value,'A more recent address');
});

test('active services block map and GPS edits', async () => {
  const r=runtime();
  r.run("activeSessionRole='client';state.active={status:'en_route'};updateLocationControls()");
  let requests=0;
  r.context.navigator.geolocation.getCurrentPosition=()=>{requests++};
  r.run("openLocationPicker('origin')");
  await r.run("useClientLocation('origin')");
  assert.equal(requests,0);
  assert.equal(r.run('locationPickerTarget'),null);
  assert.equal(r.document.getElementById('originGpsBtn').disabled,true);
});

test('only the latest quote response can update distance after endpoint edits', async () => {
  const r=runtime();
  r.run("activeSessionRole='client'");
  r.document.getElementById('origin').value='Origin A';
  r.document.getElementById('dest').value='Destination';
  const pending=[];
  r.api.functions={invoke:()=>new Promise(resolve=>pending.push(resolve))};
  const first=r.run('calculateRoute()');
  r.document.getElementById('origin').value='Origin B';
  r.run("routeInputChanged('origin')");
  const second=r.run('calculateRoute()');
  pending[1]({data:{distance_km:8}}); await second;
  pending[0]({data:{distance_km:99}}); await first;
  assert.equal(r.document.getElementById('km').value,8);
  assert.match(r.document.getElementById('routeInfo').textContent,/Origin B/);
});

test('completed-job polling preserves a new draft route and quote', async () => {
  const r=runtime([{data:{role:'client'}},{data:{}},{data:[{id:'old',status:'completed',price:400}]},{data:[]}]);
  r.run("activeSessionRole='client';state.active={id:'old',status:'completed'};routeClears=0;clearRouteOnMap=()=>{routeClears++};");
  r.document.getElementById('origin').value='21.1, -86.8';
  r.document.getElementById('dest').value='21.2, -86.9';
  r.document.getElementById('routeInfo').textContent='New draft route';
  await r.run('renderClient()');
  assert.equal(r.run('routeClears'),0);
  assert.equal(r.document.getElementById('origin').value,'21.1, -86.8');
  assert.equal(r.document.getElementById('routeInfo').textContent,'New draft route');
});


test('signout removes selected coordinates and ignores an outstanding client GPS fix', async () => {
  const r = runtime();
  r.run("activeSessionRole='client'");
  r.document.getElementById('origin').value='21.1, -86.8';
  r.document.getElementById('dest').value='21.2, -86.9';
  let finish;
  r.context.navigator.geolocation.getCurrentPosition=ok=>{finish=ok};
  const pending=r.run("useClientLocation('origin')");
  r.run('clearSignedOutView()');
  finish({coords:{latitude:21.15,longitude:-86.85,accuracy:10}});
  await pending;
  assert.equal(r.document.getElementById('origin').value,'');
  assert.equal(r.document.getElementById('dest').value,'');
  assert.equal(r.document.getElementById('km').value,'');
  assert.equal(r.document.getElementById('locationPickerModal').classList.contains('hidden'),true);
});

const requestedForCancellation = { id:'cancel-job', client_id:'driver-1', driver_id:null,
  status:'requested', origin:'A', destination:'B', price:400 };
function cancellationRuntime(responses, confirmed=true) {
 const r=runtime(responses); r.confirmations=[];
 r.context.window={confirm:message=>{r.confirmations.push(message);return confirmed;}};
 r.run("activeSessionRole='client';state.active="+JSON.stringify(requestedForCancellation)+";refreshes=0;renderClient=async()=>{refreshes++};");
 return r;
}
test('client cancellation requires confirmation and updates only the selected own unassigned request', async () => {
 const r=cancellationRuntime([{data:{role:'client'}},{data:requestedForCancellation},
  {data:{id:'cancel-job',status:'cancelled',client_id:'driver-1',driver_id:null}}]);
 await r.run('cancelClientRequest()');
 const update=r.queries.find(q=>q.calls.some(c=>c[0]==='update'));
 assert.deepEqual(JSON.parse(JSON.stringify(update.calls.find(c=>c[0]==='update')[1])),{status:'cancelled'});
 assert.deepEqual(update.calls.filter(c=>['eq','is'].includes(c[0])),[
  ['eq','id','cancel-job'],['eq','client_id','driver-1'],['eq','status','requested'],['is','driver_id',null]
 ]);
 assert.equal(r.confirmations.length,1);
 assert.equal(r.run('state.active.status'),'cancelled');
 assert.equal(r.document.getElementById('originMapBtn').disabled,false);
 assert.equal(r.document.getElementById('origin').value,'');
 assert.ok(r.messages.includes('Solicitud cancelada.'));
});
test('declining cancellation sends no update and preserves the active request', async () => {
 const r=cancellationRuntime([{data:{role:'client'}},{data:requestedForCancellation}],false);
 await r.run('cancelClientRequest()');
 assert.equal(r.queries.length,2);
 assert.equal(r.run('state.active.status'),'requested');
 assert.equal(r.run('refreshes'),0);
});
test('acceptance race or failed cancellation cannot report false success', async () => {
 for (const result of [{data:null},{data:null,error:{message:'denied'}}]) {
  const r=cancellationRuntime([{data:{role:'client'}},{data:requestedForCancellation},result]);
  await r.run('cancelClientRequest()');
  assert.ok(!r.messages.includes('Solicitud cancelada.'));
  assert.equal(r.run('refreshes'),1);
  assert.equal(r.run('state.active.status'),'requested');
 }
});
test('a request already accepted on the server cannot reach cancellation confirmation', async () => {
 const r=cancellationRuntime([{data:{role:'client'}},{data:{...requestedForCancellation,status:'en_route',driver_id:'driver-2'}}]);
 await r.run('cancelClientRequest()');
 assert.equal(r.confirmations.length,0);
 assert.equal(r.queries.length,2);
 assert.equal(r.run('refreshes'),1);
});
test('non-client accounts and non-requested jobs cannot use client cancellation', async () => {
 for (const role of ['driver','admin']) {
  const r=cancellationRuntime([{data:{role}}]);
  await r.run('cancelClientRequest()');
  assert.equal(r.confirmations.length,0);
  assert.equal(r.queries.length,1);
 }
 for (const status of ['en_route','completed','cancelled']) {
  const r=cancellationRuntime([]);r.run("state.active.status='"+status+"'");
  await r.run('cancelClientRequest()');assert.equal(r.queries.length,0);
 }
});
test('double cancellation taps start only one validation', async () => {
 const r=cancellationRuntime([{data:{role:'client'}},{data:requestedForCancellation}],false);
 let finish;r.api.auth.getUser=()=>new Promise(resolve=>{finish=resolve});
 const pending=r.run('cancelClientRequest()');await r.run('cancelClientRequest()');
 finish({data:{user:{id:'driver-1'}}});await pending;
 assert.equal(r.confirmations.length,1);
 assert.equal(r.run('clientCancellationPending'),false);
});
test('signout during cancellation validation prevents any mutation', async () => {
 const r=cancellationRuntime([]);let finish;
 r.api.auth.getUser=()=>new Promise(resolve=>{finish=resolve});
 const pending=r.run('cancelClientRequest()');r.run('clearSignedOutView()');
 finish({data:{user:{id:'driver-1'}}});await pending;
 assert.equal(r.queries.length,0);assert.equal(r.confirmations.length,0);
});
test('client history includes cancelled requests and offers cancellation only before acceptance', async () => {
 for (const status of ['requested','en_route','completed','cancelled']) {
  const job={...requestedForCancellation,status};
  const r=runtime([{data:{role:'client'}},{data:{}},{data:[job]},{data:[job]}]);
  r.run("activeSessionRole='client';restoreRouteForJob=async()=>{};startDriverTracking=()=>{};");
  await r.run('renderClient()');
  assert.equal(r.document.getElementById('clientStatus').innerHTML.includes('Cancelar solicitud'),status==='requested');
  if(status==='cancelled')assert.match(r.document.getElementById('clientHistory').innerHTML,/Cancelado/);
  assert.ok(r.queries.some(q=>q.calls.some(c=>c[0]==='in'&&c[2].includes('cancelled'))));
 }
});
test('cancelled services are excluded from admin financial amounts and counted separately', async () => {
 const jobs=[{id:'cancelled',status:'cancelled',price:100,created_at:new Date().toISOString()},
  {id:'completed',status:'completed',price:200,driver_id:'driver-1',created_at:new Date().toISOString()},
  {id:'requested',status:'requested',price:300,created_at:new Date().toISOString()}];
 const r=runtime([{data:{role:'admin'}},{data:jobs},{data:[{id:'driver-1',role:'driver',full_name:'Driver'}]},{data:[]}]);
 for(const id of ['adminSearch','adminUsersSearch','adminStatusFilter'])r.document.getElementById(id).value='';
 r.document.getElementById('adminReportPeriod').value='all';
 await r.run('renderAdmin()');
 assert.equal(r.document.getElementById('sales').textContent,r.run('money(500)'));
 assert.equal(r.document.getElementById('reportSales').textContent,r.run('money(500)'));
 assert.equal(r.document.getElementById('reportJobs').textContent,2);
 assert.equal(r.document.getElementById('cancelledCount').textContent,1);
 assert.match(r.document.getElementById('adminTable').innerHTML,/Cancelado/);
});
