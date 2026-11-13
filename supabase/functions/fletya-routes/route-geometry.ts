export function decodePolyline(encoded: string): number[][] {
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
      if (Math.abs(lat) > 9_000_000 || Math.abs(lng) > 18_000_000) return [];
      points.push([lng / 100_000, lat / 100_000]);
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

