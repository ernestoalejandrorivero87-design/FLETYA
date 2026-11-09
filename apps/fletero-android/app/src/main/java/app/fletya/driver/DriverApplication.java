package app.fletya.driver;

import android.app.Application;

public final class DriverApplication extends Application {
    private DriverApi api;
    @Override public void onCreate() {
        super.onCreate();
        try { api = new DriverApi(new SecureSessionStore(this), new HttpTransport()); }
        catch (Exception error) { throw new IllegalStateException("No se pudo iniciar el almacenamiento seguro.", error); }
    }
    DriverApi api() { return api; }
}
