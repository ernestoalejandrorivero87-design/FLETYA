import { crossesNichupteVehicularBridge, decodePolyline, insideRing } from "./route-geometry.ts";
import { pilotEndpointAreas } from "./pilot-endpoints.ts";
import { requestGuidedRoute } from "./guided-route.ts";

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

  let payload: unknown;
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ error: "invalid_json", message: "El cuerpo debe ser JSON válido." }, 400);
  }

  if (typeof payload !== "object" || payload === null) {
    return jsonResponse({ error: "invalid_input", message: "Envía origen y destino como texto." }, 400);
  }

  const { origin, destination, purpose, include_route, include_steps } = payload as Record<string, unknown>;
  const navigation = purpose === "navigation";
  const guided = navigation && include_steps === true;
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
    if (guided) {
      const supabaseUrl = Deno.env.get("SUPABASE_URL");
      const pilot = supabaseUrl === "https://wsdfqscrvfygxripmrzi.supabase.co";
      const stadiaKey = Deno.env.get(pilot ? "FLETYA_PILOT_STADIA_API_KEY" : "FLETYA_PRUEBAS_STADIA_API_KEY")?.trim();
      const endpoint = stadiaKey ? "https://api.stadiamaps.com/route/v1" : pilot ? undefined : Deno.env.get("FLETYA_PRUEBAS_VALHALLA_ROUTE_URL");
      const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
      if ((!pilot && supabaseUrl !== "https://ccdtpwvalqznasstnqxj.supabase.co") || !supabaseUrl || !anonKey) {
        return jsonResponse({ error: "guidance_unavailable", message: "La guía aún no está disponible en este entorno." }, 503);
      }
      const authorization = req.headers.get("Authorization");
      if (!authorization) return jsonResponse({ error: "authentication_required" }, 401);
      const headers = { apikey: anonKey, Authorization: authorization };
      const auth = await fetch(supabaseUrl + "/auth/v1/user", {
        headers, signal: controller.signal,
      });
      if (!auth.ok) return jsonResponse({ error: "authentication_required" }, 401);
      const { id } = await auth.json();
      if (typeof id !== "string" || !id) return jsonResponse({ error: "authentication_required" }, 401);
      const jobsUrl = new URL(supabaseUrl + "/rest/v1/jobs");
      jobsUrl.search = new URLSearchParams({
        select: "origin,destination,status",
        driver_id: "eq." + id,
        status: "in.(en_route,picked_up)",
        limit: "2",
      }).toString();
      const jobs = await fetch(jobsUrl.toString(), { headers, signal: controller.signal });
      if (!jobs.ok) return jsonResponse({ error: "job_verification_failed" }, 502);
      const active = await jobs.json();
      if (!Array.isArray(active) || active.length !== 1) {
        return jsonResponse({ error: "active_job_required", message: "La guía requiere un servicio asignado y en ruta." }, 403);
      }
      if (!endpoint?.startsWith("https://")) {
        return jsonResponse({ error: "guidance_unavailable", message: "La guía aún no está disponible en este entorno." }, 503);
      }
      const from = (originWaypoint.location as { latLng?: { latitude: number; longitude: number } } | undefined)?.latLng;
      if (!from) return jsonResponse({ error: "guidance_requires_origin_pin", message: "Activa la ubicación GPS del conductor para navegar." }, 422);
      const job = active[0];
      const jobDestination = job.status === "en_route" ? job.origin : job.destination;
      if (typeof jobDestination !== "string" || destination.trim() !== jobDestination.trim()) {
        return jsonResponse({ error: "job_destination_mismatch", message: "El destino no corresponde a la etapa del servicio." }, 422);
      }
      const waypoint = routeWaypoint(jobDestination);
      let to = (waypoint.location as { latLng?: { latitude: number; longitude: number } } | undefined)?.latLng;
      if (!to) {
        const googleKey = Deno.env.get("GOOGLE_MAPS_API_KEY");
        if (!googleKey) return jsonResponse({ error: "guidance_unavailable", message: "No está configurada la búsqueda de direcciones." }, 503);
        const geocodeUrl = new URL("https://maps.googleapis.com/maps/api/geocode/json");
        geocodeUrl.searchParams.set("address", jobDestination);
        geocodeUrl.searchParams.set("components", "country:MX");
        geocodeUrl.searchParams.set("key", googleKey);
        const geocodeResponse = await fetch(geocodeUrl, { signal: controller.signal });
        if (!geocodeResponse.ok) return jsonResponse({ error: "geocoding_unavailable", message: "No se pudo consultar la dirección." }, 502);
        const geocoded = await geocodeResponse.json() as { status?: string; results?: { geometry?: { location?: { lat: number; lng: number } }; partial_match?: boolean; address_components?: { long_name: string; short_name: string; types: string[] }[] }[] };
        const matches = geocoded.status === "OK" ? geocoded.results ?? [] : [];
        const candidates = matches.filter(result => {
          const location = result.geometry?.location;
          // Cancun metropolitan area guard; avoid relying on Google's variable state abbreviation.
          return !result.partial_match && location && Number.isFinite(location.lat) && Number.isFinite(location.lng)
            && location.lat >= 20.8 && location.lat <= 21.35 && location.lng >= -87.1 && location.lng <= -86.65;
        });
        if (candidates.length !== 1) {
          // Log only aggregate diagnostics, never the user's address or Google API key.
          console.warn("guided_geocode_unresolved", JSON.stringify({
            status: geocoded.status ?? "unknown",
            result_count: matches.length,
            local_candidate_count: candidates.length,
            partial_count: matches.filter(result => result.partial_match).length
          }));
          return jsonResponse({ error: "ambiguous_destination", message: "No se pudo identificar un destino único. Confirma la ubicación en el mapa." }, 422);
        }
        const point = candidates[0].geometry!.location!;
        if (!Number.isFinite(point.lat) || !Number.isFinite(point.lng)) return jsonResponse({ error: "invalid_destination", message: "No se pudo verificar la ubicación." }, 422);
        to = { latitude: point.lat, longitude: point.lng };
      }
      const route = await requestGuidedRoute(endpoint, from, to, controller.signal, stadiaKey);
      return route ? jsonResponse({ ...route, ...(stadiaKey ? { provider: "stadia" } : {}) })
        : jsonResponse({ error: "restricted_route", message: "No se pudo verificar una ruta con indicaciones." }, 422);
    }

    const apiKey = Deno.env.get("GOOGLE_MAPS_API_KEY");
    if (!apiKey) {
      console.error("Missing GOOGLE_MAPS_API_KEY secret");
      return jsonResponse({ error: "server_configuration_error" }, 500);
    }
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
    const getRoutes = (via?: string) => fetch(
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
          polylineQuality: "HIGH_QUALITY",
          ...(via ? { intermediates: [{ address: via, via: true }] } : { computeAlternativeRoutes: true }),
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
    let bridgeBlocked = false;
    const permittedRoute = (candidate: ProviderRoute): candidate is QuoteRoute => {
      if (!validQuoteRoute(candidate)) return false;
      const points = decodePolyline(candidate.polyline.encodedPolyline);
      if (points.length < 2 || (quote &&
          (!inPilotArea(pickup ?? points[0]) || !inPilotArea(dropoff ?? points[points.length - 1])))) return false;
      if (crossesNichupteVehicularBridge(points)) {
        bridgeBlocked = true;
        return false;
      }
      return true;
    };
    let route = routes.find(permittedRoute);
    if (!route && bridgeBlocked) {
      const alternatives = await Promise.allSettled([
        "Torre Escénica de Cancún, Boulevard Kukulcán, Cancún, Quintana Roo",
        "Playa Delfines, Boulevard Kukulcán, Cancún, Quintana Roo",
      ].map(async (via) => {
        const response = await getRoutes(via);
        if (!response.ok) return undefined;
        const detour = await response.json() as { routes?: ProviderRoute[] };
        return Array.isArray(detour.routes) ? detour.routes.find(permittedRoute) : undefined;
      }));
      route = alternatives.flatMap(result => result.status === "fulfilled" && result.value ? [result.value] : [])
        .sort((a, b) => a.distanceMeters - b.distanceMeters)[0];
    }
    if (!route && bridgeBlocked) {
      const message = "No se encontró una ruta para carga que evite el Puente Nichupté.";
      return quote ? jsonResponse({ local_quote: false, message }) : jsonResponse({ error: "restricted_route", message }, 422);
    }
    if (quote && routes.length && !route) {
      return jsonResponse({
        local_quote: false,
        message: "La recogida y la entrega deben estar dentro de la zona de servicio de FLETYA.",
      });
    }
    if (!route) {
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
    // Google Maps URLs can recalculate a route. Keep navigation in FLETYA
    // when a candidate uses the restricted bridge or the route enters its
    // area of influence, even if Google did not offer the bridge this time.
    const requiresFletyaMap = navigation && (bridgeBlocked ||
      decodePolyline(route.polyline.encodedPolyline).some(([lng, lat]) =>
        lng >= -86.82 && lng <= -86.73 && lat >= 21.025 && lat <= 21.175));
    return jsonResponse({
      ...(navigation ? { navigation_mode: requiresFletyaMap ? "fletya" : "external" } : {}),
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
    if (error instanceof Error && error.message === "guidance_provider_error") {
      return jsonResponse({ error: "guidance_provider_error", message: "El servidor de rutas no respondió correctamente." }, 502);
    }
    console.error("Unexpected error while calculating route");
    return jsonResponse({ error: "internal_error" }, 500);
  } finally {
    clearTimeout(timeout);
  }
});
