package app.fletya.client;

import org.json.JSONArray;
import org.json.JSONObject;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;

/** Calls only public Auth/PostgREST endpoints using the user's token and existing RLS. */
public final class ClientApi {
    public interface Store { JSONObject read() throws Exception; void write(JSONObject value) throws Exception; void clear(); }
    public interface Transport {
        Response send(String method, String path, String accessToken, JSONObject body, String prefer) throws Exception;
    }
    public record Response(int status, String body) {}
    public static final class Failure extends Exception {
        public final int status;
        Failure(int status, String message) { super(message); this.status = status; }
    }
    private final Store store;
    private final Transport transport;
    private volatile JSONObject session;
    private long validUntilNanos;
    public ClientApi(Store store, Transport transport) throws Exception {
        this.store = store;
        this.transport = transport;
        session = store.read(); // On process recreation always refresh, independent of wall clock.
    }
    public boolean signedIn() { return session != null; }
    public String userId() {
        JSONObject value = session;
        return value == null || value.optJSONObject("user") == null ? "" : value.optJSONObject("user").optString("id");
    }
    private void check(Response response) throws Failure {
        if (response.status() >= 200 && response.status() < 300) return;
        String message = switch (response.status()) {
            case 400, 422 -> "Revisa los datos. Si el servicio cambió, actualiza el panel.";
            case 401 -> "Tu sesión venció. Inicia sesión nuevamente.";
            case 403 -> "Esta cuenta no tiene permiso para realizar la operación.";
            case 409 -> "El servicio cambió. Actualiza el panel antes de continuar.";
            case 429 -> "Demasiados intentos. Espera un momento y vuelve a intentar.";
            default -> "No se pudo conectar con FLETYA. Revisa tu conexión.";
        };
        throw new Failure(response.status(), message);
    }
    private void saveSession(Response response) throws Exception {
        check(response);
        JSONObject value = new JSONObject(response.body());
        if (value.optString("access_token").trim().isEmpty() || value.optString("refresh_token").trim().isEmpty()
            || value.optJSONObject("user") == null || value.getJSONObject("user").optString("id").trim().isEmpty())
            throw new Failure(401, "No se pudo validar la sesión.");
        store.write(value);
        session = value;
        validUntilNanos = System.nanoTime() + Math.max(0, value.optLong("expires_in", 3600) - 60) * 1_000_000_000L;
    }
    public synchronized void login(String email, String password) throws Exception {
        if (signedIn()) throw new Failure(409, "Cierra la sesión actual antes de cambiar de cuenta.");
        try {
            saveSession(transport.send("POST", "/auth/v1/token?grant_type=password", null,
                new JSONObject().put("email", email.trim()).put("password", password), null));
            profile();
        } catch (Exception error) { clear(); throw error; }
    }
    private String token() throws Exception {
        if (session == null) throw new Failure(401, "Inicia sesión como cliente.");
        if (validUntilNanos == 0 || System.nanoTime() >= validUntilNanos) {
            Response response = transport.send("POST", "/auth/v1/token?grant_type=refresh_token", null,
                new JSONObject().put("refresh_token", session.getString("refresh_token")), null);
            if (response.status() == 400 || response.status() == 401 || response.status() == 403) {
                clear(); throw new Failure(401, "Tu sesión venció. Inicia sesión nuevamente.");
            }
            saveSession(response);
        }
        return session.getString("access_token");
    }
    private Response call(String method, String path, JSONObject body, String prefer) throws Exception {
        Response response = transport.send(method, path, token(), body, prefer);
        // A rejected access token is refreshed once; never repeat a mutation after an ambiguous network failure.
        if (response.status() == 401) {
            validUntilNanos = 0;
            response = transport.send(method, path, token(), body, prefer);
        }
        if (response.status() == 401) clear();
        check(response);
        return response;
    }
    private JSONArray get(String query) throws Exception { return new JSONArray(call("GET", "/rest/v1/" + query, null, null).body()); }
    private static String androidSafeEncode(String value) {
        try { return URLEncoder.encode(value, "UTF-8"); }
        catch (java.io.UnsupportedEncodingException impossible) { throw new IllegalStateException(impossible); }
    }
    private static String eq(String value) { return androidSafeEncode(value); }
    public synchronized JSONObject profile() throws Exception {
        token();
        JSONArray rows = get("profiles?select=id,role,full_name&id=eq." + eq(userId()));
        if (rows.length() != 1 || !userId().equals(rows.getJSONObject(0).optString("id")) || !"client".equals(rows.getJSONObject(0).optString("role"))) {
            clear(); throw new Failure(403, "Esta app es para cuentas de cliente. Usa tu cuenta de cliente.");
        }
        return rows.getJSONObject(0);
    }
    public synchronized JSONArray activeJobs() throws Exception {
        token();
        return get("jobs?select=*&client_id=eq." + eq(userId()) + "&status=in.(requested,en_route,picked_up)&order=created_at.desc,id.desc&limit=2");
    }
    public synchronized JSONArray history(int offset) throws Exception {
        token();
        return get("jobs?select=*&client_id=eq." + eq(userId()) + "&order=created_at.desc,id.desc&limit=6&offset=" + Math.max(0,offset));
    }
    public synchronized JSONObject job(String id) throws Exception {
        token();
        JSONArray rows = get("jobs?select=*&id=eq." + eq(id) + "&client_id=eq." + eq(userId()));
        if (rows.length() != 1) return null;
        JSONObject job = rows.getJSONObject(0);
        if (!ClientRules.owns(job,userId())) throw new Failure(403,"No se pudo validar el propietario del servicio.");
        return job;
    }
    public synchronized void saveName(String name) throws Exception {
        profile();
        if (name.trim().isEmpty() || name.length() > 100) throw new Failure(400,"Escribe tu nombre (hasta 100 caracteres).");
        JSONArray rows = new JSONArray(call("PATCH", "/rest/v1/profiles?id=eq." + eq(userId()) + "&role=eq.client&select=id",new JSONObject().put("full_name",name.trim()),"return=representation").body());
        if (rows.length() != 1 || !userId().equals(rows.getJSONObject(0).optString("id"))) throw new Failure(409,"No se pudo confirmar el guardado.");
    }
    public synchronized JSONObject route(String origin, String destination) throws Exception {
        return new JSONObject(call("POST","/functions/v1/fletya-routes",new JSONObject().put("origin",origin).put("destination",destination),null).body());
    }
    public record Quote(String origin,String destination,String vehicle,int helpers,String service,double km,double price,String polyline,String duration,long createdNanos) {}
    public synchronized Quote quote(String origin,String destination,String vehicle,int helpers,String service) throws Exception {
        profile();
        String from = ClientRules.address(origin), to = ClientRules.address(destination);
        if (!java.util.Arrays.asList(ClientRules.SERVICES).contains(service)) throw new Failure(400,"Elige un servicio válido.");
        ClientRules.price(1,vehicle,helpers);
        JSONObject route = route(from,to);
        double km = route.optDouble("distance_km", Double.NaN);
        double price = ClientRules.price(km,vehicle,helpers);
        return new Quote(from,to,vehicle,helpers,service,km,price,route.optString("polyline"),route.optString("duration_text"),System.nanoTime());
    }
    public synchronized JSONObject create(Quote quote,String requestId) throws Exception {
        profile();
        java.util.UUID.fromString(requestId);
        JSONObject existing = job(requestId);
        if (existing != null) return existing; // Same request UUID survives an ambiguous POST response; never duplicate it.
        if (activeJobs().length() != 0) throw new Failure(409,"Ya tienes un servicio activo. Actualiza el seguimiento.");
        long age = System.nanoTime() - quote.createdNanos();
        if (age < 0 || age > 600_000_000_000L) throw new Failure(409,"El precio venció. Calcula de nuevo antes de confirmar.");
        double price = ClientRules.price(quote.km(),quote.vehicle(),quote.helpers());
        if (Math.abs(price-quote.price()) > 0.001) throw new Failure(400,"Calcula de nuevo el precio.");
        JSONObject body = new JSONObject().put("id",requestId).put("client_id",userId()).put("origin",quote.origin())
            .put("destination",quote.destination()).put("vehicle_type",quote.vehicle()).put("helpers",quote.helpers())
            .put("service_type",quote.service()).put("distance_km",quote.km()).put("price",price);
        JSONArray rows = new JSONArray(call("POST","/rest/v1/jobs?select=*",body,"return=representation").body());
        if (rows.length() != 1 || !requestId.equals(rows.getJSONObject(0).optString("id")) || !ClientRules.owns(rows.getJSONObject(0),userId()))
            throw new Failure(409,"No se pudo confirmar la solicitud. Actualiza el seguimiento antes de volver a solicitar.");
        return rows.getJSONObject(0);
    }
    public synchronized JSONObject cancel(String id) throws Exception {
        profile();
        JSONObject job = job(id);
        if (job == null || !"requested".equals(job.optString("status")) || !job.isNull("driver_id") || job.optBoolean("driver_paid"))
            throw new Failure(409,"El servicio cambió o ya fue aceptado. Actualiza el seguimiento.");
        JSONArray rows = new JSONArray(call("PATCH","/rest/v1/jobs?id=eq." + eq(id) + "&client_id=eq." + eq(userId())
            + "&status=eq.requested&driver_id=is.null&select=*",new JSONObject().put("status","cancelled"),"return=representation").body());
        JSONObject result = rows.length() == 1 ? rows.getJSONObject(0) : null;
        if (!ClientRules.owns(result,userId()) || !id.equals(result.optString("id")) || !"cancelled".equals(result.optString("status")) || !result.isNull("driver_id"))
            throw new Failure(409,"No se pudo confirmar la cancelación. Puede haber sido aceptado; actualiza el seguimiento.");
        return result;
    }
    public record Tracking(JSONObject driver,JSONObject fix) {}
    public synchronized Tracking tracking(JSONObject job) throws Exception {
        if (!ClientRules.owns(job,userId()) || !ClientRules.assigned(job.optString("status")) || job.isNull("driver_id")) return new Tracking(null,null);
        JSONObject body = new JSONObject().put("p_job_id",job.getString("id"));
        JSONArray identity = new JSONArray(call("POST","/rest/v1/rpc/get_assigned_driver",body,null).body());
        JSONArray positions = new JSONArray(call("POST","/rest/v1/rpc/get_job_driver_location",body,null).body());
        String driverId = job.getString("driver_id");
        JSONObject driver = identity.length() == 1 && driverId.equals(identity.getJSONObject(0).optString("driver_id")) ? identity.getJSONObject(0) : null;
        JSONObject fix = positions.length() == 1 && driverId.equals(positions.getJSONObject(0).optString("driver_id")) && job.getString("id").equals(positions.getJSONObject(0).optString("job_id")) ? positions.getJSONObject(0) : null;
        if (fix != null) fix.put("observed_elapsed_nanos", System.nanoTime());
        return new Tracking(driver,fix);
    }
    public synchronized void logout() {
        try { if (session != null) transport.send("POST","/auth/v1/logout?scope=local",token(),null,null); }
        catch (Exception ignored) { /* Device-local logout works offline. */ }
        finally { clear(); }
    }
    public synchronized void clear() { session = null; validUntilNanos = 0; store.clear(); }
}
