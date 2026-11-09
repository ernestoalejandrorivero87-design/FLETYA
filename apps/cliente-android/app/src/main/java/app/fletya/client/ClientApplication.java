package app.fletya.client;
import android.app.Application;
public final class ClientApplication extends Application {
    private ClientApi api;
    @Override public void onCreate() { super.onCreate(); try { api = new ClientApi(new SecureSessionStore(this), new HttpTransport()); } catch (Exception error) { throw new IllegalStateException("No se pudo abrir la sesión", error); } }
    ClientApi api() { return api; }
}
