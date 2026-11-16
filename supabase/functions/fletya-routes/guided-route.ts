import { crossesNichupteVehicularBridge, decodePolyline, nichupteCut } from "./route-geometry.ts";

type Location = { latitude: number; longitude: number };
type Maneuver = { begin_shape_index: number; end_shape_index: number; instruction: string };
type Leg = { shape: string; maneuvers: Maneuver[] };

export async function requestGuidedRoute(endpoint: string, from: Location, to: Location, signal: AbortSignal) {
  const { longitude, south, north } = nichupteCut;
  const west = longitude - 0.0005, east = longitude + 0.0005;
  const response = await fetch(endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    redirect: "error",
    signal,
    body: JSON.stringify({
      locations: [from, to].map(({ latitude, longitude }) => ({ lat: latitude, lon: longitude, radius: 50 })),
      costing: "auto",
      language: "es-ES",
      directions_type: "instructions",
      exclude_polygons: [[[west, south], [east, south], [east, north], [west, north], [west, south]]],
    }),
  });
  if (!response.ok) return null;
  const { trip } = await response.json() as { trip?: { legs?: Leg[] } };
  if (trip?.legs?.length !== 1) return null;
  const leg = trip.legs[0];
  const points = decodePolyline(leg?.shape ?? "", 1_000_000);
  if (points.length < 2 || points.length > 8_000 || crossesNichupteVehicularBridge(points) ||
      !Array.isArray(leg.maneuvers) || leg.maneuvers.length > 250) return null;
  const steps = [];
  let cursor = 0;
  for (const maneuver of leg.maneuvers) {
    const { begin_shape_index: begin, end_shape_index: end, instruction } = maneuver;
    if (!Number.isInteger(begin) || !Number.isInteger(end) || begin !== cursor || end < begin ||
        end >= points.length || typeof instruction !== "string") return null;
    if (end > begin) steps.push({ begin, end, instruction: instruction.trim().slice(0, 240) });
    cursor = end;
  }
  return steps.length && cursor === points.length - 1 ? { points, navigation_steps: steps } : null;
}
