package app.fletya.driver;
import org.junit.Test;
import static org.junit.Assert.*;
public class RouteMapDataTest {
    @Test public void decodesKnownGooglePolyline() throws Exception {
        var points = RouteMapData.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@");
        assertEquals(3, points.length());
        assertEquals(38.5, points.getJSONArray(0).getDouble(0), 0.00001);
        assertEquals(-120.95, points.getJSONArray(1).getDouble(1), 0.00001);
        assertEquals(43.252, points.getJSONArray(2).getDouble(0), 0.00001);
    }
    @Test public void rejectsMalformedTruncatedAndOutOfRangeCoordinates() throws Exception {
        for (String value : new String[]{"", "_", "??", "<script>", "~~~~~~~~~~~~", "_p~iF~ps|U_ulL", "~~~~~~~~~~~~~~~~~~~~??"}) {
            try { RouteMapData.decode(value); fail("Accepted invalid route"); }
            catch (IllegalArgumentException expected) { /* no partial route */ }
        }
    }
}
