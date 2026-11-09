package app.fletya.driver;

import org.json.*;
import org.junit.Test;
import static org.junit.Assert.*;
import java.util.*;

public class DriverApiTest {
    static final class Memory implements DriverApi.Store {
        JSONObject value;
        public JSONObject read() { return value; }
        public void write(JSONObject v) { value = v; }
        public void clear() { value = null; }
    }
    static final class Fake implements DriverApi.Transport {
        final Queue<DriverApi.Response> responses = new ArrayDeque<>();
        final List<String> paths = new ArrayList<>();
        final List<JSONObject> bodies = new ArrayList<>();
        public DriverApi.Response send(String method, String path, String token, JSONObject body, String prefer) {
            paths.add(method + " " + path); bodies.add(body);
            if (responses.isEmpty()) throw new AssertionError("Unexpected request: " + method + " " + path);
            return responses.remove();
        }
        void reply(int code, String body) { responses.add(new DriverApi.Response(code, body)); }
    }
    private String session() { return "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_in\":3600,\"user\":{\"id\":\"driver-a\"}}"; }
    private DriverApi logged(Fake fake, Memory store) throws Exception {
        DriverApi api = new DriverApi(store, fake);
        fake.reply(200, session());
        fake.reply(200, "[{\"id\":\"driver-a\",\"role\":\"driver\"}]");
        api.login("driver@example.com", "not-persisted");
        return api;
    }
    @Test public void clientAccountIsRejectedAndSessionCleared() throws Exception {
        Fake fake = new Fake(); Memory store = new Memory(); DriverApi api = new DriverApi(store, fake);
        fake.reply(200, session()); fake.reply(200, "[{\"id\":\"driver-a\",\"role\":\"client\"}]");
        try { api.login("client@example.com", "x"); fail(); }
        catch (DriverApi.Failure error) { assertEquals(403, error.status); }
        assertFalse(api.signedIn()); assertNull(store.value);
    }
    @Test public void appRecreationRefreshesWithoutDeviceWallClock() throws Exception {
        Fake fake = new Fake(); Memory store = new Memory(); store.value = new JSONObject(session());
        DriverApi api = new DriverApi(store, fake);
        fake.reply(200, session()); fake.reply(200, "[]"); api.activeJobs();
        assertTrue(fake.paths.get(0).contains("grant_type=refresh_token"));
        assertFalse(store.value.has("password"));
    }
    @Test public void expiredRefreshClearsStoredSession() throws Exception {
        Fake fake = new Fake(); Memory store = new Memory(); store.value = new JSONObject(session());
        DriverApi api = new DriverApi(store, fake); fake.reply(400, "{}");
        try { api.activeJobs(); fail(); } catch (DriverApi.Failure error) { assertEquals(401, error.status); }
        assertFalse(api.signedIn()); assertNull(store.value);
    }
    @Test public void acceptanceConflictDoesNotReportSuccess() throws Exception {
        Fake fake = new Fake(); Memory store = new Memory(); DriverApi api = logged(fake, store);
        fake.reply(200, "[]"); fake.reply(200, "[]");
        try { api.transition("job-1", "requested", "en_route", null); fail(); }
        catch (DriverApi.Failure error) { assertEquals(409, error.status); }
        assertTrue(fake.paths.get(3).contains("status=eq.requested&driver_id=is.null"));
    }
    @Test public void activeJobPreventsSecondAcceptance() throws Exception {
        Fake fake = new Fake(); DriverApi api = logged(fake, new Memory()); fake.reply(200, "[{\"id\":\"current\"}]");
        try { api.transition("job-2", "requested", "en_route", null); fail(); }
        catch (DriverApi.Failure error) { assertEquals(409, error.status); }
        assertEquals(3, fake.paths.size());
    }
    @Test public void releaseRequiresReasonAndExactAssignment() throws Exception {
        Fake fake = new Fake(); DriverApi api = logged(fake, new Memory());
        try { api.transition("job-1", "en_route", "requested", "short"); fail(); }
        catch (DriverApi.Failure error) { assertEquals(400, error.status); }
        fake.reply(200, "[{\"id\":\"job-1\",\"status\":\"requested\",\"driver_id\":null}]");
        api.transition("job-1", "en_route", "requested", "  Vehículo averiado  ");
        assertTrue(fake.paths.get(2).contains("driver_id=eq.driver-a&driver_paid=eq.false"));
        assertTrue(fake.bodies.get(2).isNull("driver_id"));
        assertEquals("Vehículo averiado", fake.bodies.get(2).getString("release_reason"));
    }
    @Test public void completedOrReassignedJobNeverUploadsGps() throws Exception {
        for (String job : new String[]{"{\"status\":\"completed\",\"driver_id\":\"driver-a\"}", "{\"status\":\"en_route\",\"driver_id\":\"driver-b\"}"}) {
            Fake fake = new Fake(); DriverApi api = logged(fake, new Memory()); fake.reply(200, "[" + job + "]");
            assertFalse(api.uploadLocation("job-1", 21, -86, 12));
            assertEquals(3, fake.paths.size());
        }
    }
    @Test public void gpsPayloadDoesNotSupplyDeviceTimestamp() throws Exception {
        Fake fake = new Fake(); DriverApi api = logged(fake, new Memory());
        fake.reply(200, "[{\"status\":\"picked_up\",\"driver_id\":\"driver-a\"}]"); fake.reply(201, "");
        assertTrue(api.uploadLocation("job-1", 21.1, -86.8, 5));
        JSONObject body = fake.bodies.get(3);
        assertFalse(body.has("updated_at")); assertEquals("job-1", body.getString("job_id"));
        assertEquals("driver-a", body.getString("driver_id"));
    }
    @Test public void fixThatAgesDuringRequestIsNotUploaded() throws Exception {
        Fake fake = new Fake(); DriverApi api = logged(fake, new Memory());
        fake.reply(200, "[{\"status\":\"en_route\",\"driver_id\":\"driver-a\"}]");
        try { api.uploadLocation("job-1", 21, -86, 12, () -> false); fail(); }
        catch (java.io.IOException expected) { assertEquals(3, fake.paths.size()); }
    }
    @Test public void rejectedGpsTokenDoesNotReplayOldFix() throws Exception {
        Fake fake = new Fake(); DriverApi api = logged(fake, new Memory());
        fake.reply(200, "[{\"status\":\"en_route\",\"driver_id\":\"driver-a\"}]");
        fake.reply(401, "{}");
        try { api.uploadLocation("job-1", 21, -86, 12); fail(); }
        catch (DriverApi.Failure error) { assertEquals(401, error.status); }
        assertEquals(4, fake.paths.size());
    }
    @Test public void logoutClearsLocalSessionEvenOffline() throws Exception {
        Fake fake = new Fake(); Memory store = new Memory(); DriverApi api = logged(fake, store);
        fake.reply(503, "{}"); api.logout(); assertFalse(api.signedIn()); assertNull(store.value);
    }
    @Test public void profileSaveMustReturnOwnRow() throws Exception {
        Fake fake = new Fake(); DriverApi api = logged(fake, new Memory()); fake.reply(200, "[]");
        try { api.saveProfile("Ernesto", "pickup", "tb-0610-r"); fail(); }
        catch (DriverApi.Failure error) { assertEquals(409, error.status); }
        assertEquals("TB-0610-R", fake.bodies.get(2).getString("plates"));
    }
    @Test public void pickupCannotJumpDirectlyToCompletion() throws Exception {
        Fake fake = new Fake(); DriverApi api = logged(fake, new Memory());
        try { api.transition("job-1", "en_route", "completed", null); fail(); }
        catch (DriverApi.Failure error) { assertEquals(400, error.status); }
        assertEquals(2, fake.paths.size());
    }
    @Test public void gpsFixUsesMonotonicAgeAndRejectsStaleOrInvalidCoordinates() {
        assertTrue(DriverRules.freshFix(60_000_000_000L, 55_000_000_000L, 21.1, -86.8, 10));
        assertFalse(DriverRules.freshFix(60_000_000_000L, 1, 21.1, -86.8, 10));
        assertFalse(DriverRules.freshFix(60_000_000_000L, 61_000_000_000L, 21.1, -86.8, 10));
        assertFalse(DriverRules.freshFix(60_000_000_000L, 55_000_000_000L, Double.NaN, -86.8, 10));
        assertFalse(DriverRules.freshFix(60_000_000_000L, 55_000_000_000L, 91, -86.8, 10));
        assertFalse(DriverRules.freshFix(60_000_000_000L, 55_000_000_000L, 21, -186, 10));
    }
    @Test public void pushRegistrationMustReturnOwnRow() throws Exception {
        Fake fake = new Fake(); DriverApi api = logged(fake, new Memory()); fake.reply(200, "[]");
        try { api.registerPush("installation", "synthetic-fcm-token", "nonce"); fail(); }
        catch (DriverApi.Failure error) { assertEquals(409, error.status); }
        assertEquals("driver-a", fake.bodies.get(2).getString("user_id"));
        assertFalse(fake.bodies.get(2).has("session_id"));
    }
    @Test public void logoutUnregisterMatchesInstallationAndLoginNonce() throws Exception {
        Fake fake = new Fake(); DriverApi api = logged(fake, new Memory()); fake.reply(204, "");
        api.unregisterPush("installation", "login-nonce");
        assertTrue(fake.paths.get(2).contains("user_id=eq.driver-a&installation_id=eq.installation&registration_nonce=eq.login-nonce"));
        assertFalse(fake.bodies.get(2).getBoolean("enabled"));
    }
    @Test public void navigationChangesOnlyAfterPickup() {
        assertEquals("origin", DriverRules.navigationPoint("en_route", "origin", "destination"));
        assertEquals("destination", DriverRules.navigationPoint("picked_up", "origin", "destination"));
        assertFalse(DriverRules.ownsActive("picked_up", "driver-b", "driver-a"));
    }
}
