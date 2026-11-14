import { decodePolyline, insideRing } from "./route-geometry.ts";
import { pilotEndpointAreas } from "./pilot-endpoints.ts";

type ProviderRoute = { distanceMeters?: number; duration?: string; polyline?: { encodedPolyline?: string } };
type QuoteRoute = { distanceMeters: number; duration: string; polyline: { encodedPolyline: string } };
function inPilotArea(point: number[]): boolean {
  return pilotEndpointAreas.some(([outer, ...holes]) =>
    insideRing(point, outer) && !holes.some((hole) => insideRing(point, hole))
  );
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

function formatDuration(totalSeconds: number): string {
  const totalMinutes = Math.round(totalSeconds / 60);
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  return hours > 0 ? `${hours} h ${minutes} min` : `${minutes} min`;
}

function routeWaypoint(text: string): Record<string, unknown> {
  const value = text.trim();
  const match = value.match(/^([+-]?\d+(?:\.\d+)?)\s*,\s*([+-]?\d+(?:\.\d+)?)$/);
  if (!match) return { address: value };
  const latitude = Number(match[1]);
  const longitude = Number(match[2]);
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude) ||
      Math.abs(latitude) > 90 || Math.abs(longitude) > 180) {
    throw new Error("invalid_coordinates");
  }
  return { location: { latLng: { latitude, longitude } } };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "method_not_allowed", message: "Usa POST." }, 405);
  }

  const apiKey = Deno.env.get("GOOGLE_MAPS_API_KEY");
  if (!apiKey) {
    console.error("Missing GOOGLE_MAPS_API_KEY secret");
    return jsonResponse({ error: "server_configuration_error" }, 500);
  }

  let payload: unknown;
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ error: "invalid_json", message: "El cuerpo debe ser JSON válido." }, 400);
  }

  if (typeof payload !== "object" || payload === null) {
    return jsonResponse({ error: "invalid_input", message: "Envía origen y destino como texto." }, 400);
  }

  const { origin, destination, purpose, include_route } = payload as Record<string, unknown>;
  const bookable = purpose === "bookable_quote";
  const quote = purpose === "quote" || bookable;
  if (
    typeof origin !== "string" || typeof destination !== "string" ||
    origin.trim().length === 0 || destination.trim().length === 0 ||
    origin.length > 300 || destination.length > 300
  ) {
    return jsonResponse({
      error: "invalid_input",
      message: "origen y destino son obligatorios y deben tener como máximo 300 caracteres.",
    }, 400);
  }

  let originWaypoint: Record<string, unknown>;
  let destinationWaypoint: Record<string, unknown>;
  try {
    originWaypoint = routeWaypoint(origin);
    destinationWaypoint = routeWaypoint(destination);
  } catch {
    return jsonResponse({ error: "invalid_coordinates", message: "Revisa las coordenadas del origen y destino." }, 400);
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 12_000);

  try {
    const supabaseUrl = bookable ? Deno.env.get("SUPABASE_URL") : undefined;
    const anonKey = bookable ? Deno.env.get("SUPABASE_ANON_KEY") : undefined;
    const serviceKey = bookable ? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") : undefined;
    let userId: string | undefined;
    if (bookable) {
      if (!supabaseUrl || !anonKey || !serviceKey) return jsonResponse({ error: "server_configuration_error" }, 500);
      const authorization = req.headers.get("Authorization");
      if (!authorization) return jsonResponse({ error: "authentication_required", message: "Inicia sesión para cotizar." }, 401);
      const auth = await fetch(supabaseUrl + "/auth/v1/user", {
        headers: { apikey: anonKey, Authorization: authorization },
        signal: controller.signal,
      });
      if (!auth.ok) return jsonResponse({ error: "authentication_required", message: "Inicia sesión para cotizar." }, auth.status >= 500 ? 502 : 401);
      const user = await auth.json() as { id?: string };
      if (!user.id) return jsonResponse({ error: "authentication_required", message: "Inicia sesión para cotizar." }, 401);
      userId = user.id;
    }
    const getRoutes = () => fetch(
      "https://routes.googleapis.com/directions/v2:computeRoutes",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Goog-Api-Key": apiKey,
          "X-Goog-FieldMask": "routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline",
        },
        body: JSON.stringify({
          origin: originWaypoint,
          destination: destinationWaypoint,
          travelMode: "DRIVE",
          ...(quote ? {
            computeAlternativeRoutes: true,
            polylineQuality: "HIGH_QUALITY",
          } : {}),
        }),
        signal: controller.signal,
      },
    );

    const googleResponse = await getRoutes();
    if (!googleResponse.ok) {
      console.error("Google Routes API request failed", { status: googleResponse.status });
      return jsonResponse({ error: "routes_provider_error" }, 502);
    }

    const data = await googleResponse.json() as { routes?: ProviderRoute[] };
    const routes: ProviderRoute[] = Array.isArray(data?.routes) ? data.routes : [];
    const coordinate = (waypoint: Record<string, unknown>): number[] | undefined => {
      const point = (waypoint.location as {latLng?: {longitude: number; latitude: number}} | undefined)?.latLng;
      return point && [point.longitude, point.latitude];
    };
    const pickup = coordinate(originWaypoint);
    const dropoff = coordinate(destinationWaypoint);
    const validQuoteRoute = (candidate: ProviderRoute): candidate is QuoteRoute =>
      typeof candidate?.distanceMeters === "number" && Number.isFinite(candidate.distanceMeters) &&
      candidate.distanceMeters > 0 && typeof candidate.duration === "string" &&
      /^\d+(?:\.\d+)?s$/.test(candidate.duration) && typeof candidate.polyline?.encodedPolyline === "string";
    const route = quote ? routes.find((candidate) => {
      if (!validQuoteRoute(candidate)) return false;
      const points = decodePolyline(candidate.polyline.encodedPolyline);
      return points.length >= 2 && inPilotArea(pickup ?? points[0]) &&
        inPilotArea(dropoff ?? points[points.length - 1]);
    }) : routes[0];
    if (quote && routes.length && !route) {
      return jsonResponse({
        local_quote: false,
        message: "La recogida y la entrega deben estar dentro de la zona de servicio de FLETYA.",
      });
    }
    if (!route || typeof route.distanceMeters !== "number" || typeof route.duration !== "string") {
      return jsonResponse({ error: "route_not_found", message: "No se encontró una ruta para ese origen y destino." }, 404);
    }

    const durationMatch = route.duration.match(/^(\d+(?:\.\d+)?)s$/);
    if (!durationMatch) {
      console.error("Unexpected duration format from Google Routes API");
      return jsonResponse({ error: "invalid_provider_response" }, 502);
    }

    const durationSeconds = Number(durationMatch[1]);
    const distanceKm = Math.round((route.distanceMeters / 1000) * 100) / 100;
    let quoteId: string | undefined;
    if (bookable && userId && serviceKey && supabaseUrl) {
      const points = decodePolyline(route.polyline?.encodedPolyline ?? "");
      if (points.length < 2 || distanceKm <= 0) return jsonResponse({ local_quote: false, message: "No se pudo verificar la ruta." });
      quoteId = crypto.randomUUID();
      const saved = await fetch(supabaseUrl + "/rest/v1/fletya_route_quotes", {
        method: "POST",
        headers: {
          apikey: serviceKey, Authorization: "Bearer " + serviceKey,
          "Content-Type": "application/json", Prefer: "return=minimal",
        },
        body: JSON.stringify({ id: quoteId, client_id: userId, origin, destination, distance_km: distanceKm, points, via: [] }),
        signal: controller.signal,
      });
      if (!saved.ok) {
        console.error("Route quote storage failed", { status: saved.status });
        return jsonResponse({ error: "quote_storage_error", message: "No se pudo reservar la cotización. Inténtalo de nuevo." }, 502);
      }
    }
    return jsonResponse({
      ...(quote ? { local_quote: true } : {}),
      distance_km: distanceKm,
      duration_seconds: durationSeconds,
      duration_text: formatDuration(durationSeconds),
      ...(quoteId ? {
        quote_id: quoteId,
        ...(include_route === true ? { route_polyline: route.polyline?.encodedPolyline } : {}),
      } : { polyline: route.polyline?.encodedPolyline || null }),
    });
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError") {
      return jsonResponse({ error: "routes_provider_timeout" }, 504);
    }
    console.error("Unexpected error while calculating route");
    return jsonResponse({ error: "internal_error" }, 500);
  } finally {
    clearTimeout(timeout);
  }
});
