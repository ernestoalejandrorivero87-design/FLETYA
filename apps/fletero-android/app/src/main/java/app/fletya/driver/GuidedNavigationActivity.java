package app.fletya.driver;

import android.app.Activity;
import android.content.Intent;
import android.location.Location;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;
import org.json.JSONObject;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

public final class GuidedNavigationActivity extends Activity {
    private final Handler main = new Handler(Looper.getMainLooper());
    private RouteMapView map;
    private android.speech.tts.TextToSpeech voice;
    private Button voiceButton;
    private boolean voiceReady, voiceEnabled = true, voiceClosed;
    private String spokenInstruction = "";
    private int spokenBand = -1;
    private void initVoice() {
        voice = new android.speech.tts.TextToSpeech(this, result -> main.post(() -> {
            if (voiceClosed || voice == null) return;
            if (result == android.speech.tts.TextToSpeech.SUCCESS) {
                int lang = voice.setLanguage(java.util.Locale.forLanguageTag("es-MX"));
                if (lang < 0) lang = voice.setLanguage(new java.util.Locale("es"));
                voiceReady = lang >= 0;
                if (voiceReady) voice.setAudioAttributes(new android.media.AudioAttributes.Builder()
                    .setUsage(android.media.AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                    .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH).build());
            }
            voiceButton.setText(voiceReady ? (voiceEnabled ? "Voz activada" : "Voz silenciada") : "Voz no disponible");
            voiceButton.setEnabled(voiceReady);
        }));
    }
    private void say(String phrase) {
        if (voiceReady && voiceEnabled && resumed && !voiceClosed)
            voice.speak(phrase, android.speech.tts.TextToSpeech.QUEUE_FLUSH, null, "navigation");
    }
    private void resetVoice() { spokenInstruction = ""; spokenBand = -1; }
    private void announce(GuidanceProgress.Hint hint) {
        if (!voiceReady || !voiceEnabled || !resumed) return;
        String phrase = hint.instruction().trim();
        if (phrase.isEmpty()) return;
        int meters = hint.meters();
        int band = meters <= 30 ? 2 : meters <= 250 ? 1 : 0;
        if (!phrase.equals(spokenInstruction)) { spokenInstruction = phrase; spokenBand = -1; }
        if (band <= spokenBand) return;
        spokenBand = band;
        String distance = meters >= 1000 ? "En " + String.format(java.util.Locale.forLanguageTag("es-MX"),"%.1f",meters/1000.0) + " kilómetros, "
            : meters > 30 ? "En " + Math.round(meters/10.0)*10 + " metros, " : "";
        say(distance + phrase);
    }
    private TextView instruction, tripSummary;
    private double assumedKmh = 30;
    private void updateSummary(boolean valid) {
        double meters = valid ? progress.remainingMeters() : Double.NaN;
        if (!Double.isFinite(meters)) { tripSummary.setText("Distancia y llegada · calculando…"); return; }
        long minutes = (long)Math.ceil(meters / (assumedKmh * 1000 / 60));
        String distance = meters < 1000 ? Math.round(meters) + " m" : String.format(java.util.Locale.ROOT,"%.1f km",meters/1000);
        String arrival = new java.text.SimpleDateFormat("HH:mm",java.util.Locale.getDefault()).format(new java.util.Date(System.currentTimeMillis()+minutes*60_000));
        tripSummary.setText(distance + " restantes · ~" + minutes + " min · " + arrival + "\nEstimación sin tráfico en vivo");
    }
    private GuidanceProgress progress;
    private String jobId;
    private String owner;
    private String stage;
    private int offRoute;
    private long lastReroute;
    private boolean rerouting, resumed;
    private final java.util.concurrent.ExecutorService routeWorker = java.util.concurrent.Executors.newSingleThreadExecutor();
    private long lastFix;
    private boolean demo;
    private List<GuidanceProgress.Point> demoPoints;
    private int demoIndex;

    static void showDemo(Activity activity) {
        activity.startActivity(new Intent(activity, GuidedNavigationActivity.class).putExtra("demo", true));
    }

    static void show(Activity activity, String jobId, String owner, String stage, JSONObject route) {
        String payload = route.toString();
        if (payload.length() > 240_000) {
            Toast.makeText(activity, "La ruta es demasiado larga para abrir la guía.", Toast.LENGTH_LONG).show();
            return;
        }
        activity.startActivity(new Intent(activity, GuidedNavigationActivity.class)
            .putExtra("job", jobId).putExtra("owner", owner).putExtra("stage", stage).putExtra("route", payload));
    }

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        if (!"PRUEBAS".equals(BuildConfig.ENVIRONMENT)) {
            finish();
            return;
        }
        jobId = getIntent().getStringExtra("job");
        owner = getIntent().getStringExtra("owner");
        stage = getIntent().getStringExtra("stage");
        demo = getIntent().getBooleanExtra("demo", false);
        if (!demo && (owner == null || jobId == null || stage == null || !isCurrentSession())) { finish(); return; }

        var layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setOnApplyWindowInsetsListener((view, insets) -> {
            view.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(),
                insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            return insets;
        });
        var close = new Button(this);
        close.setText(demo ? "Volver a Fletero" : "Volver al servicio");
        close.setOnClickListener(view -> finish());
        layout.addView(close);
        voiceButton = new Button(this);
        voiceButton.setText("Preparando voz…");
        voiceButton.setEnabled(false);
        voiceButton.setOnClickListener(view -> {
            voiceEnabled = !voiceEnabled;
            voiceButton.setText(voiceEnabled ? "Voz activada" : "Voz silenciada");
            if (!voiceEnabled && voice != null) voice.stop();
            resetVoice();
            lastFix = 0;
        });
        layout.addView(voiceButton);
        initVoice();
        if (demo) {
            var label = new TextView(this);
            label.setPadding(24, 12, 24, 0);
            label.setText("Simulación · Ruta de ejemplo a Zona Hotelera");
            layout.addView(label);
        }
        instruction = new TextView(this);
        instruction.setPadding(24, 20, 24, 20);
        instruction.setTextSize(22);
        instruction.setText("Cargando mapa de Pruebas…");
        layout.addView(instruction);
        tripSummary = new TextView(this);
        tripSummary.setPadding(24, 8, 24, 12);
        tripSummary.setTextSize(16);
        tripSummary.setText("Distancia y llegada · calculando…");
        layout.addView(tripSummary);
        setContentView(layout);
        layout.requestApplyInsets();
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        org.json.JSONArray coordinates;
        boolean stadia;
        try {
            var route = new JSONObject(demo ? readDemoRoute() : getIntent().getStringExtra("route"));
            stadia = "stadia".equals(route.optString("provider"));
            coordinates = loadRoute(route);
        } catch (Exception invalidRoute) {
            instruction.setText("No se pudo abrir la ruta de Pruebas. Vuelve al servicio.");
            return;
        }
        map = new RouteMapView(this, ((DriverApplication) getApplication()).api());
        layout.addView(map, new LinearLayout.LayoutParams(-1, 0, 1));
        if (stadia) {
            var credit = new TextView(this);
            credit.setPadding(24, 12, 24, 12);
            credit.setText("Rutas de Stadia Maps · Atribución");
            credit.setOnClickListener(view -> {
                try { startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse("https://stadiamaps.com/attribution/"))); }
                catch (android.content.ActivityNotFoundException ignored) { }
            });
            layout.addView(credit);
        }
        map.showGuidedRoute(coordinates);
        instruction.setText(demo ? "Iniciando simulación…" : "Esperando ubicación GPS precisa…");
    }

    private org.json.JSONArray loadRoute(JSONObject route) throws Exception {
        org.json.JSONArray coordinates;
            coordinates = RouteMapData.fromLongitudeFirst(route.getJSONArray("points"));
            List<GuidanceProgress.Point> points = new ArrayList<>(coordinates.length());
            for (int i = 0; i < coordinates.length(); i++) {
                var pair = coordinates.getJSONArray(i);
                points.add(new GuidanceProgress.Point(pair.getDouble(0), pair.getDouble(1)));
            }
            var values = route.getJSONArray("navigation_steps");
            List<GuidanceProgress.Step> steps = new ArrayList<>();
            for (int i = 0; i < values.length(); i++) {
                var step = values.getJSONObject(i);
                int begin = step.getInt("begin"), end = step.getInt("end");
                if (begin < 0 || end <= begin || end >= points.size()) throw new IllegalArgumentException();
                steps.add(new GuidanceProgress.Step(points.subList(begin, end + 1), step.getString("instruction")));
            }
            progress = new GuidanceProgress(steps);
            resetVoice();
            if (demo) demoPoints = points;
        return coordinates;
    }

    private String readDemoRoute() throws Exception {
        try (var input = getAssets().open("guided-demo-route.json");
             var reader = new BufferedReader(new InputStreamReader(input, StandardCharsets.UTF_8))) {
            return reader.readLine();
        }
    }

    private boolean isCurrentSession() {
        return owner.equals(((DriverApplication) getApplication()).api().userId()) && TrackingService.runningFor(jobId);
    }

    private final Runnable follow = new Runnable() {
        @Override public void run() {
            if (!isCurrentSession()) { finish(); return; }
            updatePosition(TrackingService.recentNavigationFix(jobId));
            main.postDelayed(this, 1_000);
        }
    };

    private final Runnable replay = new Runnable() {
        @Override public void run() {
            if (demoIndex == demoPoints.size()) {
                instruction.setText("Simulación completada");
                tripSummary.setText("0 m restantes · Simulación completada");
                say("Simulación completada");
                return;
            }
            var point = demoPoints.get(demoIndex++);
            Location fix = new Location("simulation");
            fix.setLatitude(point.lat());
            fix.setLongitude(point.lng());
            fix.setAccuracy(5);
            showPosition(fix);
            main.postDelayed(this, 1200);
        }
    };

    private void updatePosition(Location fix) {
        if (fix == null || fix.getAccuracy() > 25) {
            instruction.setText("Esperando ubicación GPS precisa…");
            updateSummary(false);
            if (voice != null) voice.stop();
            resetVoice();
            if (lastFix != 0) map.updateVehicle(null);
            lastFix = 0;
            offRoute = 0;
            return;
        }
        if (fix.getElapsedRealtimeNanos() == lastFix) return;
        lastFix = fix.getElapsedRealtimeNanos();
        showPosition(fix);
    }

    private void showPosition(Location fix) {
        map.updateVehicle(fix);
        var hint = progress.update(new GuidanceProgress.Point(fix.getLatitude(), fix.getLongitude()), fix.getAccuracy());
        updateSummary(hint != null);
        if (hint == null) {
            if (demo) { instruction.setText("Siguiendo ruta de ejemplo…"); return; }
            offRoute++;
            if (offRoute == 1 && voice != null) { voice.stop(); resetVoice(); }
            instruction.setText(rerouting ? "Calculando nueva ruta…" : "Fuera de ruta · verificando ubicación…");
            if (offRoute >= 3 && !rerouting && android.os.SystemClock.elapsedRealtime() - lastReroute >= 15_000) reroute(fix);
        } else {
            offRoute = 0;
            announce(hint);
            instruction.setText(hint.meters() <= 10 ? hint.instruction() : hint.meters() + " m · " + hint.instruction());
        }
    }

    private void reroute(Location fix) {
        rerouting = true;
        lastReroute = android.os.SystemClock.elapsedRealtime();
        instruction.setText("Calculando nueva ruta…");
        say("Recalculando ruta");
        String origin = fix.getLatitude() + "," + fix.getLongitude();
        routeWorker.execute(() -> {
            try {
                JSONObject route = ((DriverApplication) getApplication()).api().navigationRoute(jobId, stage, origin, true);
                main.post(() -> {
                    rerouting = false;
                    if (isDestroyed() || !resumed || !isCurrentSession() || offRoute == 0) return;
                    try {
                        if (!"stadia".equals(route.optString("provider"))) throw new IllegalArgumentException();
                        var coordinates = loadRoute(route);
                        map.replaceGuidedRoute(coordinates);
                        offRoute = 0;
                        instruction.setText("Nueva ruta verificada");
                        updateSummary(false);
                    } catch (Exception error) { instruction.setText("Ruta alternativa no verificada. Sigue las señales de tránsito."); }
                });
            } catch (Exception error) {
                main.post(() -> { rerouting = false; if (resumed && !isDestroyed() && offRoute > 0) instruction.setText("No se pudo verificar otra ruta. Reintentando…"); });
            }
        });
    }

    @Override protected void onResume() {
        super.onResume();
        resumed = true;
        if (map != null) {
            if (demo) main.postDelayed(replay, demoIndex == 0 ? 1_500 : 1200);
            else main.post(follow);
        }
    }
    @Override protected void onPause() { resumed = false; if (voice != null) voice.stop(); resetVoice(); lastFix = 0; main.removeCallbacks(follow); main.removeCallbacks(replay); super.onPause(); }
    @Override protected void onDestroy() {
        voiceClosed = true;
        if (voice != null) { voice.stop(); voice.shutdown(); voice = null; }
        routeWorker.shutdownNow();
        main.removeCallbacksAndMessages(null);
        if (map != null) map.dispose();
        super.onDestroy();
    }
}
