package app.fletya.driver;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.media.AudioAttributes;
import android.media.RingtoneManager;
import android.os.Build;
import android.os.SystemClock;
import com.google.firebase.messaging.FirebaseMessaging;
import java.util.*;
import java.util.concurrent.*;

/** No location, idle polling or background service while waiting for an offer. */
final class PushManager {
    private static final String CHANNEL = "new_service_offers_v1";
    private static final String TAG = "fletya_offers";
    private static final ExecutorService worker = Executors.newSingleThreadExecutor();
    private static volatile String report = "Conectando avisos…";
    private static boolean pending;
    private static volatile long generation;
    private static long lastSync;
    private static SharedPreferences prefs(Context context) { return context.getSharedPreferences("push_registration", Context.MODE_PRIVATE); }
    static String report() { return report; }
    static boolean permitted(Context context) {
        NotificationChannel channel = context.getSystemService(NotificationManager.class).getNotificationChannel(CHANNEL);
        return (channel == null || channel.getImportance() != NotificationManager.IMPORTANCE_NONE)
            && (Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)
            && context.getSystemService(NotificationManager.class).areNotificationsEnabled();
    }
    // Android owns the grant. Remember only whether we already showed the first-use prompt.
    static boolean shouldRequestOnFirstUse(Context context) {
        return BuildConfig.PUSH_ENABLED && Build.VERSION.SDK_INT >= 33
            && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
            && !prefs(context).getBoolean("notification_permission_requested", false);
    }
    static void markPermissionRequested(Context context) {
        prefs(context).edit().putBoolean("notification_permission_requested", true).apply();
    }
    static synchronized void activate(Context context, DriverApi api) {
        if (!BuildConfig.PUSH_ENABLED || !api.signedIn()) return;
        SharedPreferences prefs = prefs(context);
        String user = api.userId();
        if (!user.equals(prefs.getString("user", ""))) {
            prefs.edit().putString("user", user).putString("nonce", UUID.randomUUID().toString()).remove("seen").commit();
            lastSync = 0; generation++;
        }
        syncIfActive(context, api);
    }
    static synchronized void syncIfActive(Context context, DriverApi api) {
        if (!BuildConfig.PUSH_ENABLED || !api.signedIn() || !api.userId().equals(prefs(context).getString("user", ""))) return;
        if (!permitted(context)) { report = "Permite notificaciones para recibir solicitudes con la pantalla bloqueada."; return; }
        if (pending || (lastSync != 0 && SystemClock.elapsedRealtime() - lastSync < 6 * 60 * 60 * 1000L)) return;
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        NotificationChannel channel = new NotificationChannel(CHANNEL, "Nuevas solicitudes de flete", NotificationManager.IMPORTANCE_HIGH);
        channel.setDescription("Avisos de nuevas solicitudes disponibles para fleteros.");
        channel.enableVibration(true);
        channel.setVibrationPattern(new long[]{0, 300, 150, 300});
        channel.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION), new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION).build());
        channel.setLockscreenVisibility(Notification.VISIBILITY_PRIVATE);
        manager.createNotificationChannel(channel);
        SharedPreferences prefs = prefs(context);
        String installation = prefs.getString("installation", "");
        if (installation.isEmpty()) {
            installation = UUID.randomUUID().toString(); prefs.edit().putString("installation", installation).commit();
        }
        final String device = installation, user = api.userId(), nonce = prefs.getString("nonce", "");
        final long currentGeneration = generation;
        pending = true;
        report = "Activando avisos…";
        FirebaseMessaging.getInstance().setAutoInitEnabled(true);
        FirebaseMessaging.getInstance().getToken().addOnCompleteListener(task -> {
            if (!task.isSuccessful()) {
                synchronized (PushManager.class) {
                    pending = false;
                    if (currentGeneration != generation) syncIfActive(context, api);
                    else report = "Avisos sin confirmar. Reintentando automáticamente.";
                }
                return;
            }
            worker.execute(() -> {
                try {
                    if (!user.equals(api.userId()) || !nonce.equals(prefs.getString("nonce", ""))) return;
                    api.registerPush(device, task.getResult(), nonce);
                    if (currentGeneration == generation && user.equals(api.userId()) && nonce.equals(prefs.getString("nonce", ""))) {
                        lastSync = SystemClock.elapsedRealtime(); report = "Teléfono registrado para avisos de solicitudes";
                    }
                } catch (Exception error) {
                    if (currentGeneration == generation) report = "Avisos sin confirmar. Reintentando automáticamente.";
                }
                finally { synchronized (PushManager.class) {
                    pending = false;
                    if (currentGeneration != generation) syncIfActive(context, api);
                } }
            });
        });
    }
    static synchronized void tokenChanged(Context context, DriverApi api) { generation++; lastSync = 0; syncIfActive(context, api); }
    static synchronized String[] disableLocally(Context context) {
        SharedPreferences prefs = prefs(context);
        String[] registration = {prefs.getString("installation", ""), prefs.getString("nonce", "")};
        prefs.edit().remove("user").remove("nonce").remove("seen").commit();
        lastSync = 0; generation++;
        report = "Conectando avisos…";
        if (BuildConfig.PUSH_ENABLED) FirebaseMessaging.getInstance().setAutoInitEnabled(false);
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        for (android.service.notification.StatusBarNotification notification : manager.getActiveNotifications()) {
            if (TAG.equals(notification.getTag())) manager.cancel(TAG, notification.getId());
        }
        return registration;
    }
    static synchronized void show(Context context, DriverApi api, Map<String, String> data) {
        SharedPreferences prefs = prefs(context);
        if (!BuildConfig.PUSH_ENABLED || !permitted(context) || !DriverRules.matchesPush(
                api.signedIn() ? api.userId() : "", prefs.getString("user", ""), prefs.getString("nonce", ""),
                data.get("user_id"), data.get("registration_nonce"), data.get("type"), data.get("notification_id"))) return;
        String id = data.get("notification_id");
        Set<String> seen = new LinkedHashSet<>(prefs.getStringSet("seen", Collections.emptySet()));
        if (!seen.add(id)) return;
        while (seen.size() > 100) seen.remove(seen.iterator().next());
        prefs.edit().putStringSet("seen", seen).commit();
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (manager.getNotificationChannel(CHANNEL) == null) return;
        Intent intent = new Intent(context, MainActivity.class).setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        PendingIntent open = PendingIntent.getActivity(context, 77, intent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification notification = new Notification.Builder(context, CHANNEL).setSmallIcon(R.drawable.ic_truck)
            .setContentTitle("Nueva solicitud de flete")
            .setContentText("Abre FLETYA para consultar la disponibilidad.")
            .setContentIntent(open).setAutoCancel(true).setCategory(Notification.CATEGORY_RECOMMENDATION)
            .setVisibility(Notification.VISIBILITY_PRIVATE).build();
        if (Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)
            manager.notify(TAG, id.hashCode(), notification);
    }
}
