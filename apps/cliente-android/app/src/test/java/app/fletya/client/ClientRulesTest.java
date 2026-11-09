package app.fletya.client;
import org.junit.Test;
import org.json.JSONObject;
import static org.junit.Assert.*;
public class ClientRulesTest {
    @Test public void tariffsMatchWebForAllVehiclesAndHelpers(){assertEquals(1464.35,ClientRules.price(38.41,"pickup",0),0.001);assertEquals(1412.5,ClientRules.price(18.5,"camioneta",2),0.001);assertEquals(1250,ClientRules.price(10,"camion",1),0.001);}
    @Test public void invalidTariffsAreRejected(){for(double value:new double[]{0,-1,Double.NaN,Double.POSITIVE_INFINITY})try{ClientRules.price(value,"pickup",0);fail();}catch(IllegalArgumentException expected){}try{ClientRules.price(1,"bus",0);fail();}catch(IllegalArgumentException expected){}try{ClientRules.price(1,"pickup",3);fail();}catch(IllegalArgumentException expected){}}
    @Test public void addressesKeepCoordinatesAndAddSameRegionalContext(){assertEquals("21.1, -86.8",ClientRules.address("21.1, -86.8"));assertEquals("Zona hotelera, Cancún, Quintana Roo, México",ClientRules.address("Zona hotelera"));assertEquals("Playa del Carmen, Quintana Roo, México",ClientRules.address("Playa del Carmen"));assertEquals("Tulum, México",ClientRules.address("Tulum, México"));assertNull(ClientRules.coordinates("91, -86"));}
    @Test public void freshnessRequiresServerTimeAndNeverUsesDeviceClock()throws Exception{var fix=new JSONObject().put("updated_at","2026-11-09T21:00:00Z").put("server_now","2026-11-09T21:00:30Z");assertEquals(30,ClientRules.ageSeconds(fix));assertEquals("Ubicación reciente",ClientRules.freshness(fix));fix.put("server_now","2026-11-09T21:05:00Z");assertTrue(ClientRules.freshness(fix).contains("desactualizada"));fix.remove("server_now");assertEquals(-1,ClientRules.ageSeconds(fix));fix.put("server_now","2026-11-09T20:50:00Z");assertEquals(-1,ClientRules.ageSeconds(fix));}
}
