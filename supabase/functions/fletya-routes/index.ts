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

  const { origin, destination } = payload as Record<string, unknown>;
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
    const googleResponse = await fetch(
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
        }),
        signal: controller.signal,
      },
    );

    if (!googleResponse.ok) {
      console.error("Google Routes API request failed", { status: googleResponse.status });
      return jsonResponse({ error: "routes_provider_error" }, 502);
    }

    const data = await googleResponse.json();
    const route = data?.routes?.[0];
    if (!route || typeof route.distanceMeters !== "number" || typeof route.duration !== "string") {
      return jsonResponse({ error: "route_not_found", message: "No se encontró una ruta para ese origen y destino." }, 404);
    }

    const durationMatch = route.duration.match(/^(\d+(?:\.\d+)?)s$/);
    if (!durationMatch) {
      console.error("Unexpected duration format from Google Routes API");
      return jsonResponse({ error: "invalid_provider_response" }, 502);
    }

   const durationSeconds = Number(durationMatch[1]);

   return jsonResponse({
     distance_km: Math.round((route.distanceMeters / 1000) * 100) / 100,
       duration_seconds: durationSeconds,
         duration_text: formatDuration(durationSeconds),
           polyline: route.polyline?.encodedPolyline || null,
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
