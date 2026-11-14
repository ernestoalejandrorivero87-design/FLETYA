const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { stripTypeScriptTypes } = require('node:module');

const routeDirectory = path.join(__dirname, '../../supabase/functions/fletya-routes');
const source = ['route-geometry.ts', 'pilot-endpoints.ts', 'index.ts']
  .map(file => fs.readFileSync(path.join(routeDirectory, file), 'utf8')
    .replace(/^import .*;\r?\n/gm, '').replace(/^export /gm, ''))
  .map(code => stripTypeScriptTypes(code))
  .join('\n');
function runtime() {
  let handler;
  const calls = [];
  vm.runInNewContext(source, {
    Deno: { env: { get: () => 'synthetic-test-key' }, serve: callback => { handler = callback; } },
    Request, Response, AbortController, DOMException, setTimeout, clearTimeout,
    console: { error() {} },
    fetch: async (url, options) => {
      calls.push({ url, body: JSON.parse(options.body) });
      return new Response(JSON.stringify({ routes: [{ distanceMeters: 8300,
        duration: '1320s', polyline: { encodedPolyline: 'synthetic' } }] }));
    }
  });
  return { calls, request: body => handler(new Request('https://example.test/routes', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body)
  })) };
}

test('route backend sends coordinate endpoints as Google latLng locations', async () => {
  const r = runtime();
  const response = await r.request({ origin: '21.161900, -86.851500', destination: '21.160000, -86.880000' });
  assert.equal(response.status, 200);
  assert.deepEqual(r.calls[0].body.origin, { location: { latLng: { latitude: 21.1619, longitude: -86.8515 } } });
  assert.deepEqual(r.calls[0].body.destination, { location: { latLng: { latitude: 21.16, longitude: -86.88 } } });
  assert.equal((await response.json()).distance_km, 8.3);
});

test('existing written addresses remain compatible with the routes backend', async () => {
  const r = runtime();
  const response = await r.request({ origin: 'Plaza Las Américas, Cancún', destination: 'Región 102, Cancún' });
  assert.equal(response.status, 200);
  assert.deepEqual(r.calls[0].body.origin, { address: 'Plaza Las Américas, Cancún' });
  assert.deepEqual(r.calls[0].body.destination, { address: 'Región 102, Cancún' });
});

test('a GPS or map point can be combined with a written address', async () => {
  const r = runtime();
  const response = await r.request({ origin: '21.1, -86.8', destination: 'Playa del Carmen, México' });
  assert.equal(response.status, 200);
  assert.ok(r.calls[0].body.origin.location);
  assert.deepEqual(r.calls[0].body.destination, { address: 'Playa del Carmen, México' });
});

test('invalid coordinate ranges are rejected before contacting Google', async () => {
  for (const origin of ['91, -86', '21, -181']) {
    const r = runtime();
    const response = await r.request({ origin, destination: 'Cancún' });
    assert.equal(response.status, 400);
    assert.equal((await response.json()).error, 'invalid_coordinates');
    assert.equal(r.calls.length, 0);
  }
});

test('existing input validation rejects missing, object and overlong endpoints', async () => {
  for (const origin of ['', { latitude: 21, longitude: -86 }, 'a'.repeat(301)]) {
    const r = runtime();
    assert.equal((await r.request({ origin, destination: 'Cancún' })).status, 400);
    assert.equal(r.calls.length, 0);
  }
});
