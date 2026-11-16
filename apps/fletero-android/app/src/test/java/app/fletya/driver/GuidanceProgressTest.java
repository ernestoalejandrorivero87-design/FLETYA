new
package app.fletya.driver;

import org.junit.Test;
import java.util.List;
import static org.junit.Assert.*;
import static app.fletya.driver.GuidanceProgress.*;

public class GuidanceProgressTest {
    private GuidanceProgress route() {
        var start = new Point(21.130, -86.860);
        var corner = new Point(21.131, -86.860);
        var end = new Point(21.131, -86.859);
        return new GuidanceProgress(List.of(
            new Step(List.of(start, corner), "Continúa al norte"),
            new Step(List.of(corner, end), "Gira a la derecha")
        ));
    }

    @Test public void showsUpcomingTurnAndAdvancesOnlyAfterTurning() {
        var progress = route();
        var approach = progress.update(new Point(21.1305, -86.860), 5);
        assertEquals("Gira a la derecha", approach.instruction());
        assertEquals(56, approach.meters());
        assertEquals("Destino de esta etapa",
            progress.update(new Point(21.131, -86.8597), 5).instruction());
    }

    @Test public void suppressesInstructionsOutsideVerifiedRouteOrWithWeakGps() {
        var progress = route();
        assertNull(progress.update(new Point(21.1305, -86.860), 60));
        assertNull(progress.update(new Point(21.1305, -86.861), 5));
        assertNull(progress.update(new Point(21.1305, -86.860), Double.NaN));
    }
}
