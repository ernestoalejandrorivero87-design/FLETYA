package app.fletya.client;

import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;

public final class ClientMessagingService extends FirebaseMessagingService {
    @Override public void onNewToken(String token) {
        PushManager.tokenChanged(this, ((ClientApplication) getApplication()).api());
    }
    @Override public void onMessageReceived(RemoteMessage message) {
        PushManager.show(this, ((ClientApplication) getApplication()).api(), message.getData());
    }
}
