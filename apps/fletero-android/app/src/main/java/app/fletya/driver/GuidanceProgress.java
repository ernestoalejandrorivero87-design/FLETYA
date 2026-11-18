package app.fletya.driver;

import java.util.ArrayList;
import java.util.List;

/** Tracks progress only along the previously checked route. */
final class GuidanceProgress {
    private static final double METERS_PER_DEGREE = 111_195;
    record Point(double lat, double lng) {}
    record Step(List<Point> points, String instruction) {}
    record Hint(String instruction, int meters) {}
    private record Match(double offset, double remaining) {}

    private final List<Step> steps;
    private int current;
    private double totalRemaining = Double.NaN;
    private final double[] suffix;
    private double[] seconds;
    void setDurations(double[] durations) { seconds = durations.clone(); }
    boolean hasProviderDurations() { if (seconds == null || seconds.length != steps.size()) return false; for (double s : seconds) if (!Double.isFinite(s) || s <= 0) return false; return true; }
    double remainingSeconds() {
        if (!Double.isFinite(totalRemaining)) return Double.NaN;
        if (!hasProviderDurations()) return totalRemaining / (30_000.0 / 3600);
        double length = suffix[current] - suffix[current+1];
        double fraction = length > 0 ? Math.max(0, Math.min(1, (totalRemaining-suffix[current+1])/length)) : 0;
        double result = seconds[current]*fraction;
        for (int i=current+1;i<seconds.length;i++) result += seconds[i];
        return result;
    }
    double remainingMeters() { return totalRemaining; }
    private double lastRemaining = Double.POSITIVE_INFINITY;

    GuidanceProgress(List<Step> steps) { this.steps = new ArrayList<>(steps); suffix = new double[steps.size()+1];
        for (int i=steps.size()-1;i>=0;i--) { var pts=steps.get(i).points(); suffix[i]=suffix[i+1]+match(pts.get(0),pts).remaining(); } }

    Hint update(Point position, double accuracy) {
        if (steps.isEmpty() || !Double.isFinite(accuracy) || accuracy <= 0 || accuracy > 25) return null;
        double tolerance = Math.max(18, accuracy + 8);
        Match match = match(position, steps.get(current).points());
        if (current + 1 < steps.size() && Math.min(lastRemaining, match.remaining()) < 45) {
            Match next = match(position, steps.get(current + 1).points());
            if (next.offset() <= tolerance && next.offset() + 4 < match.offset()) {
                current++;
                match = next;
            }
        }
        if (match.offset() > tolerance) { totalRemaining = Double.NaN; return null; }
        totalRemaining = match.remaining() + suffix[current+1];
        lastRemaining = match.remaining();
        double remaining = match.remaining();
        for (int i = current + 1; i < steps.size(); i++) {
            Step next = steps.get(i);
            if (!next.instruction().trim().isEmpty()) return new Hint(next.instruction(), (int) Math.round(remaining));
            remaining += match(next.points().get(0), next.points()).remaining();
        }
        return new Hint("Destino de esta etapa", (int) Math.round(remaining));
    }

    private static Match match(Point p, List<Point> points) {
        double lngScale = METERS_PER_DEGREE * Math.cos(Math.toRadians(p.lat()));
        double best = Double.POSITIVE_INFINITY;
        double projected = 0;
        double length = 0;
        for (int i = 1; i < points.size(); i++) {
            Point a = points.get(i - 1), b = points.get(i);
            double x = (a.lng() - p.lng()) * lngScale, y = (a.lat() - p.lat()) * METERS_PER_DEGREE;
            double dx = (b.lng() - a.lng()) * lngScale, dy = (b.lat() - a.lat()) * METERS_PER_DEGREE;
            double squared = dx * dx + dy * dy;
            if (squared == 0) continue;
            double fraction = Math.max(0, Math.min(1, -(x * dx + y * dy) / squared));
            double offset = Math.hypot(x + fraction * dx, y + fraction * dy);
            double segmentLength = Math.sqrt(squared);
            if (offset < best) {
                best = offset;
                projected = length + fraction * segmentLength;
            }
            length += segmentLength;
        }
        return new Match(best, length - projected);
    }
}
