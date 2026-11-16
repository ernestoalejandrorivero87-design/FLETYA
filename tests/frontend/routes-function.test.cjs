const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { stripTypeScriptTypes } = require('node:module');

const routeDirectory = path.join(__dirname, '../../supabase/functions/fletya-routes');
const source = ['route-geometry.ts', 'pilot-endpoints.ts', 'guided-route.ts', 'index.ts']
  .map(file => fs.readFileSync(path.join(routeDirectory, file), 'utf8')
    .replace(/^import .*;\r?\n/gm, '').replace(/^export /gm, ''))
  .map(code => stripTypeScriptTypes(code))
  .join('\n');
function encodeRoute(points, scale = 1e5) {
  let latitude = 0;
  let longitude = 0;
  function delta(value) {
    let unsigned = value < 0 ? -value * 2 - 1 : value * 2;
    let result = '';
    while (unsigned >= 32) {
      result += String.fromCharCode((unsigned & 31) + 95);
      unsigned >>= 5;
    }
    return result + String.fromCharCode(unsigned + 63);
  }
  return points.map(([lng, lat]) => {
    const nextLat = Math.round(lat * scale);
    const nextLng = Math.round(lng * scale);
    const value = delta(nextLat - latitude) + delta(nextLng - longitude);
    latitude = nextLat;
    longitude = nextLng;
    return value;
  }).join('');
}
function route(points, distanceMeters = 8300) {
  return { distanceMeters, duration: '1320s', polyline: { encodedPolyline: encodeRoute(points) } };
}
function runtime(googleRoutes = () => [route([[-86.8515, 21.1619], [-86.88, 21.16]])], valhalla) {
  let handler;
  const calls = [];
  vm.runInNewContext(source, {
    Deno: { env: { get: key => key.endsWith('_URL') ? 'https://example.test/route' : 'synthetic-test-key' }, serve: callback => { handler = callback; } },
    Request, Response, AbortController, DOMException, setTimeout, clearTimeout,
    console: { error() {} },
    fetch: async (url, options) => {
      if (url.endsWith('/auth/v1/user')) return new Response(JSON.stringify({ id: 'simulated-driver' }));
      calls.push({ url, body: JSON.parse(options.body) });
      if (url === 'https://example.test/route') return new Response(JSON.stringify(valhalla));
      return new Response(JSON.stringify({ routes: googleRoutes(calls.at(-1).body) }));
    }
  });
  return { calls, request: (body, authenticated = false) => handler(new Request('https://example.test/routes', {
    method: 'POST', headers: { 'Content-Type': 'application/json',
      ...(authenticated ? { Authorization: 'Bearer synthetic-session' } : {}) }, body: JSON.stringify(body)
  })) };
}

test('guided navigation requests an exclusion and refuses routes crossing the bridge', async () => {
  const start = [-86.8515, 21.1619], destination = [-86.768, 21.11];
  const bridgePoints = [start, [-86.82, 21.14], [-86.79, 21.127], destination];
  const alternate = [start, [-86.82, 21.154], [-86.79, 21.146], destination];
  const withInstructions = points => ({
    trip: { legs: [{ shape: encodeRoute(points, 1e6), maneuvers: [
      { begin_shape_index: 0, end_shape_index: 1, instruction: 'Continúa' },
      { begin_shape_index: 1, end_shape_index: 3, instruction: 'Gira a la derecha' },
      { begin_shape_index: 3, end_shape_index: 3, instruction: 'Llegaste' },
    ] }] },
  });
  const body = { origin: '21.1619,-86.8515', destination: '21.11,-86.768', purpose: 'navigation', include_steps: true };
  const blocked = runtime(undefined, withInstructions(bridgePoints));
  assert.equal((await blocked.request(body)).status, 401);
  assert.equal(blocked.calls.length, 0);
  assert.equal((await blocked.request(body, true)).status, 422);
  assert.equal(blocked.calls[0].body.language, 'es-ES');
  assert.equal(blocked.calls[0].body.exclude_polygons.length, 1);
  const safe = runtime(undefined, withInstructions(alternate));
  const response = await safe.request(body, true);
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.deepEqual(result.points, alternate);
  assert.deepEqual(result.navigation_steps, [
    { begin: 0, end: 1, instruction: 'Continúa' },
    { begin: 1, end: 3, instruction: 'Gira a la derecha' },
  ]);
});

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


test('a flete uses the distance of the allowed Google alternative in either direction', async () => {
  const start = [-86.8515, 21.1619];
  const end = [-86.768, 21.11];
  const bridge = [start, [-86.82, 21.14], [-86.79, 21.127], end];
  const north = [start, [-86.82, 21.154], [-86.79, 21.146], end];
  for (const reverse of [false, true]) {
    const oriented = points => reverse ? points.slice().reverse() : points;
    const r = runtime(() => [route(oriented(bridge)), route(oriented(north), 16500)]);
    const response = await r.request({ origin: oriented([start, end])[0].slice().reverse().join(','),
      destination: oriented([start, end])[1].slice().reverse().join(',') });
    assert.equal(response.status, 200);
    assert.equal((await response.json()).distance_km, 16.5);
    assert.equal(r.calls.length, 1);
  }
});

test('a blocked bridge route tries both detours and fails closed if they still cross', async () => {
  const start = [-86.8515, 21.1619];
  const end = [-86.768, 21.11];
  const bridge = route([start, [-86.82, 21.14], [-86.79, 21.127], end]);
  const south = route([start, [-86.84, 21.058], [-86.78, 21.06], end], 24000);
  const input = { origin: 'Cancún centro', destination: 'Plaza La Isla, Cancún' };
  const r = runtime(body => body.intermediates?.[0].address.startsWith('Playa Delfines') ? [south] : [bridge]);
  const response = await r.request(input);
  assert.equal((await response.json()).distance_km, 24);
  assert.equal(r.calls.length, 3);
  const blocked = await runtime(() => [bridge]).request(input);
  assert.equal(blocked.status, 422);
  assert.equal((await blocked.json()).error, 'restricted_route');
});

test('navigation stays in FLETYA near Nichupté even with a safe Google route', async () => {
  const r = runtime(() => [route([[-86.85, 21.13], [-86.804, 21.152], [-86.768, 21.11]])]);
  const response = await r.request({ origin: '21.13,-86.85', destination: '21.11,-86.768', purpose: 'navigation' });
  assert.equal((await response.json()).navigation_mode, 'fletya');
  const outside = await runtime().request({ origin: '21.1619,-86.8515', destination: '21.16,-86.88', purpose: 'navigation' });
  assert.equal((await outside.json()).navigation_mode, 'external');
});


test('quotes include access and interior roads for both residential developments', async () => {
  const urban = [-86.8515, 21.1619];
  for (const residential of [
    [-86.84989, 21.0596], [-86.85964, 21.05974], [-86.84837, 21.05455],
    [-86.87372, 21.00427], [-86.879113, 21.002171], [-86.87566, 20.99735],
  ]) {
    for (const [origin, destination] of [[urban, residential], [residential, urban]]) {
      const r = runtime(() => [route([origin, destination])]);
      const coordinate = ([lng, lat]) => lat + ',' + lng;
      const response = await r.request({ origin: coordinate(origin), destination: coordinate(destination), purpose: 'quote' });
      assert.equal((await response.json()).local_quote, true, coordinate(residential));
    }
  }
});

test('the residential coverage does not extend to a nearby destination outside both areas', async () => {
  const start = [-86.8515, 21.1619];
  const outside = [-86.86199, 20.98512];
  const r = runtime(() => [route([start, outside])]);
  const response = await r.request({ origin: '21.1619,-86.8515', destination: '20.98512,-86.86199', purpose: 'quote' });
  assert.equal((await response.json()).local_quote, false);
});
