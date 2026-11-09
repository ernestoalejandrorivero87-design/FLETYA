package app.fletya.client;
import org.junit.Test;
import static org.junit.Assert.*;
public class ClientNoticesTest {
    @Test public void eventsAreBoundToCurrentUserAndLoginNonce(){String id="11111111-1111-4111-8111-111111111111";assertTrue(ClientNotices.matchesPush("a","a","new","a","new","client_completed",id));assertFalse(ClientNotices.matchesPush("b","b","new","a","new","client_completed",id));assertFalse(ClientNotices.matchesPush("a","a","new","a","old","client_completed",id));assertFalse(ClientNotices.matchesPush("a","a","new","a","new","new_service",id));assertFalse(ClientNotices.matchesPush("a","a","new","a","new","client_completed","bad"));}
    @Test public void localReceiptTimeUsesCancun(){assertTrue(ClientNotices.time("2026-11-09T22:50:32Z").contains("5:50"));assertEquals("Hora no disponible",ClientNotices.time("bad"));}
}
