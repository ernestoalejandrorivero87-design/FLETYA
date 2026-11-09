package app.fletya.client;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.text.Normalizer;
import java.time.OffsetDateTime;
import java.util.Locale;
import org.json.JSONObject;

final class ClientRules {
    static final String[] VEHICLES = {"pickup", "camioneta", "camion"};
    static final String[] SERVICES = {"Mudanza", "Flete de muebles", "Materiales", "Paquetería"};
    static boolean active(String state) { return "requested".equals(state) || assigned(state); }
    static boolean assigned(String state) { return "en_route".equals(state) || "picked_up".equals(state); }
    static boolean owns(JSONObject job, String user) { return job != null && !user.isEmpty() && user.equals(job.optString("client_id")); }
    static String status(String state) {
        return switch (state) { case "requested" -> "Buscando fletero"; case "en_route" -> "En camino a recoger"; case "picked_up" -> "Carga recogida · En camino a la entrega"; case "completed" -> "Completado"; case "cancelled" -> "Cancelado"; default -> "Estado no disponible"; };
    }
    static String vehicle(String code) { return switch(code) { case "pickup" -> "Pickup / Estaquita"; case "camioneta" -> "Camioneta"; case "camion" -> "Camión"; default -> "Sin registrar"; }; }
    static double price(double km, String vehicle, int helpers) {
        if (!Double.isFinite(km) || km <= 0 || helpers < 0 || helpers > 2) throw new IllegalArgumentException("Revisa distancia y ayudantes.");
        int rate = switch(vehicle) { case "pickup" -> 35; case "camioneta" -> 45; case "camion" -> 65; default -> throw new IllegalArgumentException("Elige un vehículo válido."); };
        int extra = "camioneta".equals(vehicle) ? 100 : "camion".equals(vehicle) ? 300 : 0;
        return BigDecimal.valueOf(km).multiply(BigDecimal.valueOf(rate)).add(BigDecimal.valueOf(120 + extra + helpers * 180)).setScale(2, RoundingMode.HALF_UP).doubleValue();
    }
    static double[] coordinates(String value) {
        if (value == null || !value.trim().matches("[+-]?\\d+(\\.\\d+)?\\s*,\\s*[+-]?\\d+(\\.\\d+)?")) return null;
        String[] parts = value.split(","); double lat = Double.parseDouble(parts[0].trim()), lng = Double.parseDouble(parts[1].trim());
        return validPoint(lat, lng) ? new double[]{lat,lng} : null;
    }
    static boolean validPoint(double lat, double lng) { return Double.isFinite(lat) && Double.isFinite(lng) && Math.abs(lat) <= 90 && Math.abs(lng) <= 180; }
    static String address(String text) {
        String value = text.trim();
        if (value.isEmpty() || value.length() > 250) throw new IllegalArgumentException("Escribe una dirección de hasta 250 caracteres.");
        if (coordinates(value) != null) return value;
        if (value.matches("[+-]?[\\d.]+\\s*,\\s*[+-]?[\\d.]+")) throw new IllegalArgumentException("Coordenadas fuera de rango.");
        String normalized = Normalizer.normalize(value.toLowerCase(Locale.ROOT), Normalizer.Form.NFD).replaceAll("\\p{M}", "");
        if (normalized.contains("quintana roo") || normalized.contains("mexico")) return value;
        for (String city : new String[]{"cancun", "playa del carmen", "puerto morelos", "tulum", "cozumel", "isla mujeres", "felipe carrillo puerto", "chetumal"})
            if (normalized.contains(city)) return value + ", Quintana Roo, México";
        return value + ", Cancún, Quintana Roo, México";
    }
    static long ageSeconds(JSONObject fix) {
        try {
            long update = OffsetDateTime.parse(fix.getString("updated_at")).toInstant().toEpochMilli();
            long now = OffsetDateTime.parse(fix.getString("server_now")).toInstant().toEpochMilli();
            if (now - update < -60_000) return -1;
            long elapsed = fix.has("observed_elapsed_nanos") ? Math.max(0, System.nanoTime()-fix.getLong("observed_elapsed_nanos"))/1_000_000_000L : 0;
            return Math.max(0, (now - update) / 1000) + elapsed;
        } catch (Exception error) { return -1; }
    }
    static String freshness(JSONObject fix) {
        long age = ageSeconds(fix);
        return age < 0 ? "Hora de ubicación no disponible" : age <= 60 ? "Ubicación reciente" : "Ubicación desactualizada · hace " + Math.max(1,age/60) + " min";
    }
}
