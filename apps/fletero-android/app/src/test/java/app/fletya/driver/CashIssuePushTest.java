package app.fletya.driver;
import org.junit.Test;
import static org.junit.Assert.*;
public class CashIssuePushTest {
    @Test public void cashIssueEventsRequireCurrentDriverAndNonce() {
        String id="11111111-1111-4111-8111-111111111111";
        assertTrue(DriverRules.matchesPush("a","a","nonce","a","nonce","new_service",id));
        assertTrue(DriverRules.matchesPush("a","a","nonce","a","nonce","cash_issue_payment_required",id));
        assertTrue(DriverRules.matchesPush("a","a","nonce","a","nonce","cash_issue_paid",id));
        assertFalse(DriverRules.matchesPush("a","a","nonce","a","stale","cash_issue_paid",id));
        assertFalse(DriverRules.matchesPush("a","a","nonce","other","nonce","cash_issue_paid",id));
        assertFalse(DriverRules.matchesPush("a","a","nonce","a","nonce","cash_issue_urgent",id));
    }
}
