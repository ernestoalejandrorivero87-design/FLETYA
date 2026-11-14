package app.fletya.driver;

import org.json.JSONArray;

/** Bounded Google encoded-polyline decoder; only numeric coordinates reach the map script. */
final class RouteMapData {
    static JSONArray decode(String encoded) throws Exception {
        if (encoded == null || encoded.isEmpty() || encoded.length() > 200_000) throw new IllegalArgumentException("Ruta inválida");
        JSONArray points = new JSONArray();
        int[] cursor = {0}; long lat = 0, lng = 0;
        while (cursor[0] < encoded.length()) {
            lat += component(encoded, cursor); lng += component(encoded, cursor);
            if (Math.abs(lat) > 9_000_000 || Math.abs(lng) > 18_000_000 || points.length() >= 50_000)
                throw new IllegalArgumentException("Coordenadas inválidas");
            points.put(new JSONArray().put(lat / 100000.0).put(lng / 100000.0));
        }
        if (points.length() < 2) throw new IllegalArgumentException("Ruta incompleta");
        return points;
    }
    static JSONArray fromLongitudeFirst(JSONArray source) throws Exception {
        if (source.length() < 2 || source.length() > 50_000) throw new IllegalArgumentException("Ruta inválida");
        JSONArray points = new JSONArray();
        for (int index = 0; index < source.length(); index++) {
            JSONArray pair = source.getJSONArray(index);
            double lng = pair.getDouble(0), lat = pair.getDouble(1);
            if (!Double.isFinite(lat) || !Double.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) {
                throw new IllegalArgumentException("Coordenadas inválidas");
            }
            points.put(new JSONArray().put(lat).put(lng));
        }
        return points;
    }

    private static long component(String value, int[] cursor) {
        long result = 0;
        for (int shift = 0; shift <= 30; shift += 5) {
            if (cursor[0] >= value.length()) throw new IllegalArgumentException("Ruta incompleta");
            int b = value.charAt(cursor[0]++) - 63;
            if (b < 0 || b > 63) throw new IllegalArgumentException("Ruta inválida");
            result |= (long)(b & 31) << shift;
            if (b < 32) return (result & 1) != 0 ? ~(result >> 1) : result >> 1;
        }
        throw new IllegalArgumentException("Ruta inválida");
    }
}
