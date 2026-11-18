export function decodePolyline(encoded: string, scale = 100_000): number[][] {
  if (!encoded || encoded.length > 100_000) return [];
  let offset = 0;
  let lat = 0;
  let lng = 0;
  const points: number[][] = [];
  function delta(): number {
    let value = 0;
    for (let shift = 0; shift <= 25; shift += 5) {
      const chunk = encoded.charCodeAt(offset++) - 63;
      if (!Number.isInteger(chunk) || chunk < 0 || chunk > 63) throw new Error("Invalid polyline");
      value += (chunk & 31) * 2 ** shift;
      if (chunk < 32) return value % 2 ? -(value + 1) / 2 : value / 2;
    }
    throw new Error("Invalid polyline");
  }
  try {
    while (offset < encoded.length) {
      lat += delta();
      lng += delta();
      if (Math.abs(lat) > 90 * scale || Math.abs(lng) > 180 * scale) return [];
      points.push([lng / scale, lat / scale]);
    }
  } catch {
    return [];
  }
  return points;
}

export function insideRing([x, y]: number[], ring: number[][]): boolean {
  let inside = false;
  for (let i = 1; i < ring.length; i++) {
    const [ax, ay] = ring[i - 1];
    const [bx, by] = ring[i];
    if ((ay > y) !== (by > y) && x < ax + (bx - ax) * (y - ay) / (by - ay)) inside = !inside;
  }
  return inside;
}

// Cut over the lagoon near the mapped midpoint of the vehicular bridge.
// https://agepro.qroo.gob.mx/proyecto-puente-vehicular-nichupte/
export const nichupteCut = { longitude: -86.80347, south: 21.125, north: 21.142 };

export function crossesNichupteVehicularBridge(points: number[][]): boolean {
  const { longitude, south, north } = nichupteCut;
  for (let i = 1; i < points.length; i++) {
    const [ax, ay] = points[i - 1];
    const [bx, by] = points[i];
    if (Math.min(ax, bx) > longitude || Math.max(ax, bx) < longitude) continue;
    if (ax === bx) {
      if (Math.min(ay, by) <= north && Math.max(ay, by) >= south) return true;
      continue;
    }
    const latitude = ay + (by - ay) * (longitude - ax) / (bx - ax);
    if (latitude >= south && latitude <= north) return true;
  }
  return false;
}
