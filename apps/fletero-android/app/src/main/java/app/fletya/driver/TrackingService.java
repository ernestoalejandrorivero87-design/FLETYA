package app.fletya.driver;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.location.*;
import android.os.*;
import java.util.concurrent.*;
import org.json.JSONObject;

/** Started only from a visible driver activity with permission and an active assignment. */
public final class TrackingService extends Service implements LocationListener {
    private static final String CHANNEL = "active_service_location";
    private static final int NOTIFICATION = 41;
    private static volatile String currentJob = "";
    private static volatile String report = "Ubicación detenida";
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private LocationManager locations;
    private DriverApi api;
    private String jobId = "";
    private String driverId = "";
    private volatile boolean stopped;
    private boolean sending;
    private long lastSentNanos;
    private long lastFixNanos;
    private Location latest;

    static String report() { return report; }
    static boolean runningFor(String id) { return !id.trim().isEmpty() && id.equals(currentJob); }
    @Override public void onCreate() {
        super.onCreate();
        api = ((DriverApplication) getApplication()).api();
        locations = getSystemService(LocationManager.class);
        getSystemService(NotificationManager.class).createNotificationChannel(
            new NotificationChannel(CHANNEL, "Ubicación del servicio", NotificationManager.IMPORTANCE_LOW));
    }
    private Notification notification(String message) {
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(this, CHANNEL).setSmallIcon(app.fletya.driver.R.drawable.ic_truck)
            .setContentTitle("FLETYA · Servicio activo").setContentText(message).setContentIntent(open)
            .setOngoing(true).setOnlyAlertOnce(true).setCategory(Notification.CATEGORY_SERVICE).build();
    }
    private void status(String value) {
        if (stopped) return;
        report = value;
        getSystemService(NotificationManager.class).notify(NOTIFICATION, notification(value));
    }
    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null || !api.signedIn()) { stopSelf(); return START_NOT_STICKY; }
        String requested = intent.getStringExtra("job_id");
        if (requested == null || requested.trim().isEmpty()) { stopSelf(); return START_NOT_STICKY; }
        if (!jobId.trim().isEmpty()) { // Do not switch an ongoing tracker by stale activity intent.
            if (!jobId.equals(requested)) stopSelf();
            return START_NOT_STICKY;
        }
        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            report = "Activa la ubicación precisa para compartir el servicio."; stopSelf(); return START_NOT_STICKY;
        }
        jobId = requested;
        driverId = api.userId();
        currentJob = jobId;
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION, notification("Comprobando servicio y buscando GPS…"), ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION);
            else startForeground(NOTIFICATION, notification("Comprobando servicio y buscando GPS…"));
            report = "Buscando ubicación…";
            if (!locations.isLocationEnabled()) { status("Activa la ubicación del teléfono."); stopSelf(); return START_NOT_STICKY; }
            for (String provider : new String[]{LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER}) {
                if (locations.isProviderEnabled(provider)) locations.requestLocationUpdates(provider, 5_000, 0, this, Looper.getMainLooper());
            }
            main.post(tick);
        } catch (RuntimeException error) { report = "No se pudo iniciar el GPS. Abre FLETYA y revisa los permisos."; stopSelf(); }
        return START_NOT_STICKY; // No prohibited background restart after process death/force stop.
    }
    private final Runnable tick = new Runnable() {
        @Override public void run() {
            if (stopped) return;
            if (!sending) {
                sending = true;
                Location fix = latest == null ? null : new Location(latest);
                worker.execute(() -> {
                    String message = null;
                    boolean end = false;
                    try {
                        if (stopped || !driverId.equals(api.userId())) return;
                        JSONObject job = api.job(jobId);
                        if (job == null || !DriverRules.ownsActive(job.optString("status"), job.optString("driver_id"), driverId)) {
                            end = true;
                        } else if (fix != null && DriverRules.freshFix(SystemClock.elapsedRealtimeNanos(), fix.getElapsedRealtimeNanos(),
                                fix.getLatitude(), fix.getLongitude(), fix.getAccuracy())
                                && fix.getElapsedRealtimeNanos() > lastFixNanos
                                && SystemClock.elapsedRealtimeNanos() - lastSentNanos >= 10_000_000_000L) {
                            if (stopped || !driverId.equals(api.userId())) return;
                            if (!api.uploadLocation(jobId, fix.getLatitude(), fix.getLongitude(), fix.getAccuracy(),
                                    () -> !stopped && DriverRules.freshFix(SystemClock.elapsedRealtimeNanos(), fix.getElapsedRealtimeNanos(), fix.getLatitude(), fix.getLongitude(), fix.getAccuracy()))) end = true;
                            else {
                                lastFixNanos = fix.getElapsedRealtimeNanos();
                                lastSentNanos = SystemClock.elapsedRealtimeNanos();
                                message = "Ubicación enviada · precisión " + Math.round(fix.getAccuracy()) + " m";
                            }
                        } else if (lastSentNanos == 0 || SystemClock.elapsedRealtimeNanos() - lastSentNanos > 30_000_000_000L) {
                            message = "Esperando una ubicación GPS nueva…";
                        }
                    } catch (Exception error) {
                        message = api.signedIn() ? "Sin envío confirmado. Revisa la conexión y el GPS." : "Sesión finalizada. Abre FLETYA.";
                        end = !api.signedIn();
                    } finally {
                        String result = message;
                        boolean stop = end;
                        main.post(() -> {
                            sending = false;
                            if (stopped) return;
                            if (stop) { report = "Ubicación detenida: servicio o sesión finalizados."; stopSelf(); }
                            else if (result != null) status(result);
                        });
                    }
                });
            }
            main.postDelayed(this, 5_000);
        }
    };
    @Override public void onLocationChanged(Location value) {
        if (!stopped && (latest == null || value.getElapsedRealtimeNanos() > latest.getElapsedRealtimeNanos())) latest = value;
    }
    @Override public void onProviderDisabled(String provider) { status("Buscando señal GPS. Revisa la ubicación del teléfono."); }
    @Override public void onProviderEnabled(String provider) { status("Buscando ubicación…"); }
    @Override public void onStatusChanged(String provider, int status, Bundle extras) { }
    @Override public void onDestroy() {
        stopped = true;
        currentJob = "";
        main.removeCallbacksAndMessages(null);
        if (locations != null) locations.removeUpdates(this);
        latest = null;
        worker.shutdownNow();
        stopForeground(STOP_FOREGROUND_REMOVE);
        if (!report.contains("finalizad")) report = "Ubicación detenida";
        super.onDestroy();
    }
    @Override public IBinder onBind(Intent intent) { return null; }
}
