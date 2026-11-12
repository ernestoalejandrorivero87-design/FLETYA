package app.fletya.driver;

import org.json.JSONArray;
import org.json.JSONObject;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;

/** Calls only public Auth/PostgREST endpoints using the user's token and existing RLS. */
public final class DriverApi {
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
    public DriverApi(Store store, Transport transport) throws Exception {
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
    public synchronized void register(String name,String email,String password,String phone,String vehicle,String plates) throws Exception {
        if (signedIn()) throw new Failure(409,"Cierra sesión antes de registrar otra cuenta.");
        name=name.trim();email=email.trim();phone=phone.trim();plates=plates.trim().toUpperCase(java.util.Locale.ROOT);
        if(name.isEmpty()||name.length()>100||!email.matches("[^\\s@]+@[^\\s@]+\\.[^\\s@]+")||password.length()<8)
            throw new Failure(400,"Escribe nombre, correo válido y una contraseña de al menos 8 caracteres.");
        if(true && (!phone.matches("\\+?[0-9]{10,15}")||!java.util.Arrays.asList("pickup","camioneta","camion").contains(vehicle)||!plates.matches("[A-Z0-9 -]{3,15}")))
            throw new Failure(400,"Completa teléfono (10 a 15 dígitos), vehículo y placas válidas.");
        JSONObject data=new JSONObject().put("full_name",name).put("role","driver").put("phone",phone);
        if(true)data.put("vehicle_type",vehicle).put("plates",plates);
        Response response=transport.send("POST","/auth/v1/signup",null,new JSONObject().put("email",email).put("password",password).put("data",data),null);
        check(response);
        // Confirmation is explicit. Never persist a password or auto-enter an unverified registration.
        JSONObject result=new JSONObject(response.body());
        if(!result.optString("access_token").isEmpty())try{transport.send("POST","/auth/v1/logout?scope=local",result.getString("access_token"),null,null);}catch(Exception ignored){}
    }
    public synchronized void recover(String email) throws Exception {
        if(signedIn())throw new Failure(409,"Cierra sesión antes de recuperar otra cuenta.");
        if(!email.trim().matches("[^\\s@]+@[^\\s@]+\\.[^\\s@]+"))throw new Failure(400,"Escribe un correo válido.");
        check(transport.send("POST","/auth/v1/recover?redirect_to=https%3A%2F%2Ffletya.vercel.app",null,new JSONObject().put("email",email.trim()),null));
    }
    public synchronized void resendConfirmation(String email) throws Exception {
        if(signedIn())throw new Failure(409,"Cierra sesión antes de reenviar la confirmación.");
        check(transport.send("POST","/auth/v1/resend",null,new JSONObject().put("type","signup").put("email",email.trim()),null));
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
        if (session == null) throw new Failure(401, "Inicia sesión como fletero.");
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
        JSONArray rows = get("profiles?select=id,role,full_name,phone,vehicle_type,plates,driver_status&id=eq." + eq(userId()));
        if (rows.length() != 1 || !"driver".equals(rows.getJSONObject(0).optString("role"))) {
            clear(); throw new Failure(403, "Esta app es para cuentas de fletero. Usa tu cuenta de fletero.");
        }
        return rows.getJSONObject(0);
    }
    public synchronized JSONArray activeJobs() throws Exception {
        token();
        return get("jobs?select=*&driver_id=eq." + eq(userId()) + "&status=in.(en_route,picked_up)&order=created_at.desc,id.desc&limit=2");
    }
    public synchronized JSONArray offers() throws Exception {
        return get("jobs?select=*&status=eq.requested&driver_id=is.null&order=created_at.desc,id.desc&limit=20");
    }
    public synchronized JSONArray history(int offset) throws Exception {
        token();
        return get("jobs?select=*&driver_id=eq." + eq(userId()) + "&status=eq.completed&order=created_at.desc,id.desc&limit=6&offset=" + Math.max(0, offset));
    }
    public synchronized JSONObject job(String id) throws Exception {
        JSONArray rows = get("jobs?select=*&id=eq." + eq(id));
        return rows.length() == 1 ? rows.getJSONObject(0) : null;
    }
    public synchronized JSONObject transition(String id, String from, String to, String reason) throws Exception {
        token();
        String user = userId();
        boolean accepting = "requested".equals(from) && "en_route".equals(to);
        boolean releasing = "en_route".equals(from) && "requested".equals(to);
        if (!(accepting || releasing || ("en_route".equals(from) && "picked_up".equals(to))
            || ("picked_up".equals(from) && "completed".equals(to))))
            throw new Failure(400, "Cambio de estado no válido.");
        if (accepting && activeJobs().length() != 0)
            throw new Failure(409, "Completa o libera tu servicio actual antes de aceptar otro.");
        JSONObject changes = new JSONObject().put("status", to);
        if (accepting) changes.put("driver_id", user);
        if (releasing) {
            if (!DriverRules.validReason(reason == null ? "" : reason))
                throw new Failure(400, "Escribe un motivo de 10 a 300 caracteres.");
            changes.put("driver_id", JSONObject.NULL).put("release_reason", reason.trim());
        }
        String query = "jobs?id=eq." + eq(id) + "&status=eq." + from
            + (accepting ? "&driver_id=is.null" : "&driver_id=eq." + eq(user))
            + (releasing ? "&driver_paid=eq.false" : "") + "&select=*";
        JSONArray rows = new JSONArray(call("PATCH", "/rest/v1/" + query, changes, "return=representation").body());
        if (rows.length() != 1) throw new Failure(409, "El servicio cambió. Actualiza el panel para comprobar su estado.");
        JSONObject job = rows.getJSONObject(0);
        if (!id.equals(job.optString("id")) || !to.equals(job.optString("status"))
            || (!releasing && !user.equals(job.optString("driver_id")))
            || (releasing && !job.isNull("driver_id")))
            throw new Failure(409, "No se pudo confirmar el cambio de estado.");
        return job;
    }
    public synchronized void arrive(String jobId,String stop) throws Exception {
        JSONObject current=job(jobId);
        String expected="pickup".equals(stop)?"en_route":"delivery".equals(stop)?"picked_up":"";
        if(current==null||expected.isEmpty()||!expected.equals(current.optString("status"))||!userId().equals(current.optString("driver_id")))throw new Failure(409,"La asignación o la etapa del servicio cambió.");
        call("POST","/rest/v1/job_arrivals?on_conflict=job_id,driver_id,stop,assignment_cycle",new JSONObject().put("job_id",jobId).put("driver_id",userId()).put("stop",stop),"resolution=ignore-duplicates,return=minimal");
    }
    public synchronized void saveProfile(String name, String vehicle, String plates) throws Exception { saveProfile(name,vehicle,plates,null); }
    public synchronized void saveProfile(String name, String vehicle, String plates,String phone) throws Exception {
        token();
        if(phone!=null&&!phone.matches("\\+?[0-9]{10,15}"))throw new Failure(400,"Escribe un teléfono de 10 a 15 dígitos.");
        plates = plates.trim().toUpperCase(java.util.Locale.ROOT);
        if (name.trim().isEmpty() || !java.util.Arrays.asList("pickup", "camioneta", "camion").contains(vehicle)
            || !plates.matches("[A-Z0-9 -]{3,15}"))
            throw new Failure(400, "Completa tu nombre, vehículo y placas válidas.");
        JSONArray rows = new JSONArray(call("PATCH", "/rest/v1/profiles?id=eq." + eq(userId()) + "&role=eq.driver&select=id",
            new JSONObject().put("full_name", name.trim()).put("vehicle_type", vehicle).put("plates", plates).putOpt("phone",phone), "return=representation").body());
        if (rows.length() != 1 || !userId().equals(rows.getJSONObject(0).optString("id")))
            throw new Failure(409, "No se pudo confirmar el guardado del perfil.");
    }
    public synchronized boolean uploadLocation(String jobId, double lat, double lng, float accuracy) throws Exception {
        return uploadLocation(jobId, lat, lng, accuracy, () -> true);
    }
    public synchronized boolean uploadLocation(String jobId, double lat, double lng, float accuracy, java.util.function.BooleanSupplier stillFresh) throws Exception {
        JSONObject job = job(jobId); // Never upload under an assignment cached before release/completion.
        if (job == null || !DriverRules.ownsActive(job.optString("status"), job.optString("driver_id"), userId())) return false;
        // Refresh before checking freshness so a slow auth request cannot make an old fix look new.
        String access = token();
        if (!stillFresh.getAsBoolean()) throw new java.io.IOException("Esperando un punto GPS nuevo");
        Response response = transport.send("POST", "/rest/v1/driver_locations?on_conflict=driver_id", access,
            new JSONObject().put("driver_id", userId()).put("job_id", jobId)
                .put("latitude", lat).put("longitude", lng).put("accuracy", accuracy),
            "resolution=merge-duplicates,return=minimal"); // Server stamps updated_at.
        if (response.status() == 401) validUntilNanos = 0; // Retry only with a new fix on the next cycle.
        check(response);
        return true;
    }
    public synchronized JSONObject route(String jobId) throws Exception {
        JSONObject assigned = job(jobId);
        if (assigned == null || !DriverRules.ownsActive(assigned.optString("status"), assigned.optString("driver_id"), userId()))
            throw new Failure(403, "El servicio ya no está asignado a tu cuenta.");
        if (!assigned.isNull("route_quote_id")) {
            JSONObject route = new JSONObject(call("POST", "/rest/v1/rpc/get_job_delivery_route",
                new JSONObject().put("p_job", jobId), null).body());
            if (!route.optBoolean("available")) throw new Failure(409, "La ruta ya no está disponible.");
            return route;
        }
        return new JSONObject(call("POST", "/functions/v1/fletya-routes", new JSONObject()
            .put("origin", assigned.optString("origin")).put("destination", assigned.optString("destination")), null).body());
    }
    public synchronized void registerPush(String installation, String token, String nonce) throws Exception {
        token();
        JSONArray rows = new JSONArray(call("POST", "/rest/v1/driver_push_devices?on_conflict=user_id,installation_id&select=user_id",
            new JSONObject().put("user_id", userId()).put("installation_id", installation).put("token", token)
                .put("registration_nonce", nonce).put("enabled", true),
            "resolution=merge-duplicates,return=representation").body());
        if (rows.length() != 1 || !userId().equals(rows.getJSONObject(0).optString("user_id")))
            throw new Failure(409, "No se pudo confirmar el registro de avisos.");
    }
    public synchronized void unregisterPush(String installation, String nonce) throws Exception {
        if (!signedIn() || nonce.isEmpty()) return;
        call("PATCH", "/rest/v1/driver_push_devices?user_id=eq." + eq(userId()) + "&installation_id=eq." + eq(installation)
            + "&registration_nonce=eq." + eq(nonce), new JSONObject().put("enabled", false), "return=minimal");
    }
    public synchronized void logout() {
        try { if (session != null) transport.send("POST", "/auth/v1/logout?scope=local", token(), null, null); }
        catch (Exception ignored) { /* Local logout must work offline. */ }
        finally { clear(); }
    }
    public synchronized void clear() { session = null; validUntilNanos = 0; store.clear(); }
}
