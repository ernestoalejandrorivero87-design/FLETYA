package app.fletya.driver;

/** Shared, platform-independent decisions. Database RLS remains authoritative. */
public final class DriverRules {
    private DriverRules() {}
    public static boolean active(String status) {
        return "en_route".equals(status) || "picked_up".equals(status);
    }
    public static boolean ownsActive(String status, String assigned, String user) {
        return user != null && !user.trim().isEmpty() && user.equals(assigned) && active(status);
    }
    public static boolean freshFix(long nowNanos, long fixNanos, double lat, double lng, float accuracy) {
        long age = nowNanos - fixNanos;
        return fixNanos > 0 && age >= 0 && age <= 30_000_000_000L
            && Double.isFinite(lat) && lat >= -90 && lat <= 90
            && Double.isFinite(lng) && lng >= -180 && lng <= 180
            && Float.isFinite(accuracy) && accuracy >= 0;
    }
    public static boolean validReason(String reason) {
        int length = reason.trim().codePointCount(0, reason.trim().length());
        return length >= 10 && length <= 300;
    }
    public static boolean matchesPush(String signedInUser, String registeredUser, String nonce,
                                      String recipient, String messageNonce, String type, String id) {
        if (signedInUser == null || signedInUser.isEmpty() || !signedInUser.equals(registeredUser)
            || !signedInUser.equals(recipient) || nonce == null || nonce.isEmpty() || !nonce.equals(messageNonce)
            || !"new_service".equals(type)) return false;
        try { return java.util.UUID.fromString(id).toString().equals(id.toLowerCase(java.util.Locale.ROOT)); }
        catch (RuntimeException invalid) { return false; }
    }
    public static String navigationPoint(String status, String origin, String destination) {
        return "picked_up".equals(status) ? destination : origin;
    }
}
