package app.fletya.driver;

import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;

public final class DriverMessagingService extends FirebaseMessagingService {
    @Override public void onNewToken(String token) {
        PushManager.tokenChanged(this, ((DriverApplication) getApplication()).api());
    }
    @Override public void onMessageReceived(RemoteMessage message) {
        PushManager.show(this, ((DriverApplication) getApplication()).api(), message.getData());
    }
}
