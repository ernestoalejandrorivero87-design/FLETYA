package app.fletya.client;
import org.json.*;
import org.junit.Test;
import static org.junit.Assert.*;
import java.util.*;

public class ClientApiTest {
    private static final String ID="219f29a6-7ec1-49b4-9701-7ac0e23a1c77";
    static final class Memory implements ClientApi.Store {
        JSONObject value;
        public JSONObject read(){return value;}
        public void write(JSONObject v){value=v;}
        public void clear(){value=null;}
    }
    static final class Fake implements ClientApi.Transport {
        final Queue<ClientApi.Response> replies=new ArrayDeque<>();
        final List<String> paths=new ArrayList<>();final List<JSONObject> bodies=new ArrayList<>();
        public ClientApi.Response send(String method,String path,String token,JSONObject body,String prefer){paths.add(method+" "+path);bodies.add(body);if(replies.isEmpty())throw new AssertionError("Unexpected request: "+method+" "+path);return replies.remove();}
        void reply(int status,String body){replies.add(new ClientApi.Response(status,body));}
        void profile(){reply(200,"[{\"id\":\"client-a\",\"role\":\"client\",\"full_name\":\"Cliente A\"}]");}
    }
    private String session(){return "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_in\":3600,\"user\":{\"id\":\"client-a\"}}";}
    private ClientApi login(Fake fake,Memory store)throws Exception{var api=new ClientApi(store,fake);fake.reply(200,session());fake.profile();api.login("client@example.com","secret-not-stored");return api;}
    private ClientApi.Quote quote(){return new ClientApi.Quote("21,-86","20,-87","pickup",0,"Mudanza",38.41,1464.35,"encoded","52 min",System.nanoTime());}
    private String job(String status,String driver){return "{\"id\":\""+ID+"\",\"client_id\":\"client-a\",\"status\":\""+status+"\",\"driver_id\":"+(driver==null?"null":"\""+driver+"\"")+"}";}
    @Test public void nativeRegistrationFixesTheRoleAndDoesNotCreateASession()throws Exception{
        Fake fake=new Fake();Memory store=new Memory();ClientApi api=new ClientApi(store,fake);fake.reply(200,"{\"user\":{\"id\":\"new-account\"}}");
        api.register("New account","new@example.com","eightcharacters","9981234567","pickup","TEST-123");
        assertEquals("POST /auth/v1/signup",fake.paths.get(0));assertEquals("client",fake.bodies.get(0).getJSONObject("data").getString("role"));assertFalse(fake.bodies.get(0).getJSONObject("data").has("driver_status"));assertFalse(api.signedIn());assertNull(store.value);
    }
    @Test public void passwordRecoveryUsesTheSharedVerifiedWebReturn()throws Exception{
        Fake fake=new Fake();ClientApi api=new ClientApi(new Memory(),fake);fake.reply(200,"{}");api.recover("user@example.com");assertTrue(fake.paths.get(0).startsWith("POST /auth/v1/recover?redirect_to="));assertEquals("user@example.com",fake.bodies.get(0).getString("email"));assertFalse(api.signedIn());
    }
    @Test public void rejectsDriverAndAdminAccountsAndClearsSession()throws Exception{
        for(String role:new String[]{"driver","admin"}){var fake=new Fake();var store=new Memory();var api=new ClientApi(store,fake);fake.reply(200,session());fake.reply(200,"[{\"id\":\"client-a\",\"role\":\""+role+"\"}]");try{api.login("x","y");fail();}catch(ClientApi.Failure e){assertEquals(403,e.status);}assertFalse(api.signedIn());assertNull(store.value);}
    }
    @Test public void restoredSessionRefreshesAndQueriesOnlyOwnActiveJobs()throws Exception{
        var fake=new Fake();var store=new Memory();store.value=new JSONObject(session());var api=new ClientApi(store,fake);fake.reply(200,session());fake.reply(200,"[]");api.activeJobs();assertTrue(fake.paths.get(0).contains("grant_type=refresh_token"));assertTrue(fake.paths.get(1).contains("client_id=eq.client-a"));assertFalse(store.value.has("password"));
    }
    @Test public void expiredRefreshClearsDeviceSession()throws Exception{
        var fake=new Fake();var store=new Memory();store.value=new JSONObject(session());var api=new ClientApi(store,fake);fake.reply(400,"{}");try{api.activeJobs();fail();}catch(ClientApi.Failure e){assertEquals(401,e.status);}assertFalse(api.signedIn());
    }
    @Test public void quoteUsesRealRouteAndExistingTariff()throws Exception{
        var fake=new Fake();var api=login(fake,new Memory());fake.profile();fake.reply(200,"{\"distance_km\":38.41,\"polyline\":\"encoded\",\"duration_text\":\"52 min\"}");var q=api.quote("21,-86","20,-87","pickup",0,"Mudanza");assertEquals(1464.35,q.price(),0.001);assertEquals("POST /functions/v1/fletya-routes",fake.paths.get(3));assertEquals("21,-86",fake.bodies.get(3).getString("origin"));
    }
    @Test public void missingDistanceCannotProduceQuoteOrRequest()throws Exception{
        var fake=new Fake();var api=login(fake,new Memory());fake.profile();fake.reply(200,"{\"polyline\":\"encoded\"}");try{api.quote("21,-86","20,-87","pickup",0,"Mudanza");fail();}catch(IllegalArgumentException expected){}assertEquals(4,fake.paths.size());
    }
    @Test public void createSendsOnlyClientOwnedUnassignedRequestAndExactPrice()throws Exception{
        var fake=new Fake();var api=login(fake,new Memory());fake.profile();fake.reply(200,"[]");fake.reply(200,"[]");fake.reply(201,"["+job("requested",null)+"]");var result=api.create(quote(),ID);assertEquals(ID,result.getString("id"));JSONObject body=fake.bodies.get(5);assertEquals("client-a",body.getString("client_id"));assertEquals(ID,body.getString("id"));assertEquals(1464.35,body.getDouble("price"),0.001);assertFalse(body.has("driver_id"));assertFalse(body.has("driver_paid"));
    }
    @Test public void uncertainResponseRetryReusesRequestIdWithoutSecondInsert()throws Exception{
        var fake=new Fake();var api=login(fake,new Memory());fake.profile();fake.reply(200,"["+job("en_route","driver-a")+"]");assertEquals("en_route",api.create(quote(),ID).getString("status"));assertEquals(4,fake.paths.size());assertFalse(fake.paths.stream().anyMatch(p->p.startsWith("POST /rest/v1/jobs")));
    }
    @Test public void existingActiveJobPreventsAnotherInsert()throws Exception{
        var fake=new Fake();var api=login(fake,new Memory());fake.profile();fake.reply(200,"[]");fake.reply(200,"["+job("requested",null)+"]");try{api.create(quote(),ID);fail();}catch(ClientApi.Failure e){assertEquals(409,e.status);}assertEquals(5,fake.paths.size());
    }
    @Test public void cancellationRaceCannotReportFalseSuccess()throws Exception{
        var fake=new Fake();var api=login(fake,new Memory());fake.profile();fake.reply(200,"["+job("requested",null)+"]");fake.reply(200,"[]");try{api.cancel(ID);fail();}catch(ClientApi.Failure e){assertEquals(409,e.status);}assertTrue(fake.paths.get(4).contains("client_id=eq.client-a&status=eq.requested&driver_id=is.null"));assertEquals("{\"status\":\"cancelled\"}",fake.bodies.get(4).toString());
    }
    @Test public void acceptedJobCannotBeCancelled()throws Exception{
        var fake=new Fake();var api=login(fake,new Memory());fake.profile();fake.reply(200,"["+job("en_route","driver-a")+"]");try{api.cancel(ID);fail();}catch(ClientApi.Failure e){assertEquals(409,e.status);}assertEquals(4,fake.paths.size());
    }
    @Test public void mismatchedTrackingRowsAreDiscarded()throws Exception{
        var fake=new Fake();var api=login(fake,new Memory());fake.reply(200,"[{\"driver_id\":\"driver-b\"}]");fake.reply(200,"[{\"driver_id\":\"driver-a\",\"job_id\":\"other-job\",\"latitude\":1}]");var tracking=api.tracking(new JSONObject(job("en_route","driver-a")));assertNull(tracking.driver());assertNull(tracking.fix());
    }
    @Test public void completedAndOtherClientJobsDoNotQueryDriverRpc()throws Exception{
        var fake=new Fake();var api=login(fake,new Memory());assertNull(api.tracking(new JSONObject(job("completed","driver-a"))).fix());assertNull(api.tracking(new JSONObject(job("en_route","driver-a").replace("client-a","client-b"))).fix());assertEquals(2,fake.paths.size());
    }
    @Test public void localLogoutPreservesOtherAppSessionsEvenWhenServerFails()throws Exception{
        var fake=new Fake();var api=login(fake,new Memory());fake.reply(500,"{}");api.logout();assertFalse(api.signedIn());assertEquals("POST /auth/v1/logout?scope=local",fake.paths.get(2));
    }
}
