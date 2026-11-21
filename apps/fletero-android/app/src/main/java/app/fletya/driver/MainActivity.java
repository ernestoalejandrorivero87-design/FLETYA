package app.fletya.driver;

import app.fletya.maps.RouteMapActivity;
import app.fletya.ui.Appearance;
import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.*;
import android.text.InputType;
import android.view.*;
import android.widget.*;
import org.json.*;
import java.text.NumberFormat;
import java.util.Locale;
import java.util.concurrent.*;

/** Native driver-only UI. Requests are serialized; late results cannot restore a logged-out screen. */
public final class MainActivity extends Activity {
    private Appearance appearance;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private DriverApi api;
    private LinearLayout root;
    private TextView message;
    private ScrollView currentScroll;
    private String renderedScreen = "";
    private boolean visible, busy, requestingNotices;
    private long revision;
    private String screen = "login";
    private JSONObject active;
    private int historyPage;
    private String permissionAcceptId;
    private RouteMapView routeMap;
    private AlertDialog offerRouteDialog;
    private String previewedOfferId = "";

    @Override public void onCreate(Bundle state) {
        appearance = new Appearance(this, R.style.AppTheme, R.style.AppThemeDark);
        setTheme(appearance.theme());
        super.onCreate(state);
        appearance.applyWindow();
        api = ((DriverApplication) getApplication()).api();
        if (api.signedIn()) { screen = "home"; shell(); }
        else loginScreen();
    }
    @Override public void onResume() {
        super.onResume(); visible = true;
        if (api.signedIn() && !"profile".equals(screen)) refresh();
        main.postDelayed(poll, 10_000);
    }
    @Override public void onPause() { visible = false; main.removeCallbacks(poll); super.onPause(); }
    @Override public void onDestroy() { revision++; main.removeCallbacksAndMessages(null); closeOfferRoute(); clearRoute(); worker.shutdownNow(); super.onDestroy(); }
    private final Runnable poll = new Runnable() {
        @Override public void run() {
            if (!visible) return;
            if (api.signedIn() && "home".equals(screen) && !busy) refresh();
            main.postDelayed(this, 10_000);
        }
    };
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private void shell() {
        int scrollY = currentScroll != null && screen.equals(renderedScreen) ? currentScroll.getScrollY() : 0;
        renderedScreen = screen;
        ScrollView scroll = new ScrollView(appearance.context()); currentScroll = scroll;
        scroll.post(() -> scroll.scrollTo(0, scrollY));
        scroll.setFillViewport(true);
        root = new LinearLayout(appearance.context()); root.setOrientation(LinearLayout.VERTICAL); root.setPadding(dp(20), dp(16), dp(20), dp(28));
        root.setBackgroundColor(appearance.canvas());
        scroll.addView(root);
        scroll.setOnApplyWindowInsetsListener((view, insets) -> {
            if (Build.VERSION.SDK_INT >= 30) {
                android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.ime());
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            } else view.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(), insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            return insets;
        });
        setContentView(scroll);
        scroll.requestApplyInsets();
        LinearLayout heading = new LinearLayout(appearance.context());
        heading.setGravity(Gravity.CENTER_VERTICAL);
        root.addView(heading);
        appearance.addBrand(heading);
        if (api.signedIn()) button(heading, "Menú", () -> showMenu(heading), false).setLayoutParams(new LinearLayout.LayoutParams(dp(96), dp(48)));
        text(root, "Fletero · " + BuildConfig.ENVIRONMENT, 12, false);
        appearance.addAccent(root);
        message = text(root, "", 14, false); message.setTextColor(appearance.accent());
    }
    private LinearLayout card(String title) {
        LinearLayout box = new LinearLayout(appearance.context()); box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(18), dp(18), dp(18), dp(18)); box.setBackground(appearance.card());
        LinearLayout.LayoutParams layout = new LinearLayout.LayoutParams(-1, -2); layout.topMargin = dp(14); root.addView(box, layout);
        text(box, title, 20, true); return box;
    }
    private TextView text(LinearLayout parent, String value, int size, boolean bold) {
        TextView view = new TextView(appearance.context()); view.setText(value); view.setTextSize(size); view.setTextColor(appearance.text());
        if (bold) view.setTypeface(null, Typeface.BOLD);
        view.setPadding(0, dp(4), 0, dp(8)); parent.addView(view); return view;
    }
    private Button button(LinearLayout parent, String label, Runnable action) {
        return button(parent, label, action, true);
    }
    private Button button(LinearLayout parent, String label, Runnable action, boolean primary) {
        Button button = new Button(appearance.context());
        button.setText(label);
        appearance.styleButton(button, primary);
        LinearLayout.LayoutParams layout = new LinearLayout.LayoutParams(-1, -2); layout.topMargin = dp(8); parent.addView(button, layout);
        button.setOnClickListener(view -> { if (!busy) action.run(); }); return button;
    }
    private EditText field(LinearLayout box, String label, String initial, int type) {
        text(box, label, 14, true);
        EditText value = new EditText(appearance.context()); value.setSingleLine(true); value.setText(initial); value.setTextSize(16); value.setInputType(type);
        value.setMinHeight(dp(48)); appearance.styleField(value); box.addView(value, new LinearLayout.LayoutParams(-1, -2)); return value;
    }
    private interface Work<T> { T run() throws Exception; }
    private interface Done<T> { void run(T result) throws Exception; }
    private <T> void task(Work<T> work, Done<T> done) {
        if (busy) return;
        busy = true;
        if (message != null) message.setText("Consultando…");
        long current = revision;
        worker.execute(() -> {
            try {
                T result = work.run();
                main.post(() -> {
                    if (isDestroyed() || current != revision) return;
                    busy = false;
                    try { done.run(result); }
                    catch (Exception error) { fail(error); }
                });
            } catch (Exception error) {
                main.post(() -> { if (!isDestroyed() && current == revision) { busy = false; fail(error); } });
            }
        });
    }
    private void fail(Exception error) {
        String value = error instanceof DriverApi.Failure ? error.getMessage() : "No se pudo conectar. Revisa tu conexión y vuelve a intentar.";
        if (!api.signedIn() && !"login".equals(screen)) {
            stopService(new Intent(this, TrackingService.class)); PushManager.disableLocally(this); active = null; loginScreen();
        }
        message.setText(value);
    }
    private void registrationScreen() {
        screen="register";shell();
        LinearLayout box=card(true?"Crear cuenta de fletero":"Crear cuenta de cliente");
        EditText name=field(box,"Nombre completo","",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_CAP_WORDS);
        EditText email=field(box,"Correo electrónico","",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS);
        EditText password=field(box,"Contraseña (mínimo 8 caracteres)","",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_PASSWORD);password.setSaveEnabled(false);
        EditText repeat=field(box,"Repite la contraseña","",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_PASSWORD);repeat.setSaveEnabled(false);
        EditText phone=true?field(box,"Teléfono con lada (10 a 15 dígitos)","",InputType.TYPE_CLASS_PHONE):null;
        Spinner vehicle=new Spinner(appearance.context());
        vehicle.setAdapter(new ArrayAdapter<>(appearance.context(),android.R.layout.simple_spinner_dropdown_item,new String[]{"Camioneta pickup","Estaquita abierta","Estaquita caja seca","Camión 3.5 t"}));
        if(true){text(box,"Vehículo",14,true);box.addView(vehicle,new LinearLayout.LayoutParams(-1,dp(52)));}
        EditText plates=true?field(box,"Placas","",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS):null;
        if(true)text(box,"Después de confirmar tu correo, tu cuenta quedará pendiente de revisión por administración. Podrás completar tus datos desde Mi perfil.",14,false);
        button(box,"Crear cuenta",()->{
            String fullName=name.getText().toString(),address=email.getText().toString(),secret=password.getText().toString();
            if(!secret.equals(repeat.getText().toString())){message.setText("Las contraseñas no coinciden.");return;}
            String telephone=phone==null?"":phone.getText().toString(),plate=plates==null?"":plates.getText().toString();String code=new String[]{"pickup","estaquita_abierta","estaquita_caja_seca","camion_3_5t"}[vehicle.getSelectedItemPosition()];
            task(()->{api.register(fullName,address,secret,telephone,code,plate);return true;},ok->{password.setText("");repeat.setText("");screen="verify";shell();LinearLayout confirmation=card("Confirma tu correo");text(confirmation,"Si el registro procede, recibirás un correo de FLETYA. Abre el enlace de confirmación y vuelve a esta app para iniciar sesión.",16,false);button(confirmation,"Reenviar confirmación",()->task(()->{api.resendConfirmation(address);return true;},sent->message.setText("Si corresponde, enviamos otro correo. Revisa también spam.")));button(root,"Ya confirmé · Iniciar sesión",this::loginScreen);});
        });
        button(root,"Volver a iniciar sesión",this::loginScreen);
    }
    private void recoveryScreen() {
        screen="recover";shell();LinearLayout box=card("Recuperar contraseña");
        EditText email=field(box,"Correo de tu cuenta","",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS);
        text(box,"Te enviaremos un enlace para elegir una contraseña nueva. Después vuelve a la app e inicia sesión.",15,false);
        button(box,"Enviar enlace de recuperación",()->{String address=email.getText().toString();task(()->{api.recover(address);return true;},ok->message.setText("Si existe una cuenta con ese correo, recibirás el enlace. Revisa también spam."));});
        button(root,"Volver a iniciar sesión",this::loginScreen);
    }
    private void loginScreen() {
        closeOfferRoute(); clearRoute(); screen = "login"; shell();
        LinearLayout box = card("Entra como fletero");
        text(box, "Usa tu cuenta de fletero de FLETYA.", 15, false);
        EditText email = field(box, "Correo electrónico", "", InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS);
        EditText password = field(box, "Contraseña", "", InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        password.setSaveEnabled(false);
        button(box, "Iniciar sesión", () -> {
            String address = email.getText().toString().trim();
            String secret = password.getText().toString();
            if (address.trim().isEmpty() || secret.trim().isEmpty()) { message.setText("Escribe tu correo y contraseña."); return; }
            task(() -> { api.login(address, secret); return true; }, result -> {
                password.setText(""); screen = "home"; refresh();
            });
        });
        button(box,"Crear cuenta de fletero",this::registrationScreen);
        button(box,"Olvidé mi contraseña",this::recoveryScreen);
        button(box, "Abrir FLETYA web", () -> open("https://fletya.vercel.app"));
    }
    private record Panel(JSONObject profile, JSONArray active, JSONArray offers) {}
    private void refresh() {
        if (busy || !visible || requestingNotices || !api.signedIn()) return;
        if ("history".equals(screen)) { history(); return; }
        if ("profile".equals(screen) || "appearance".equals(screen)) return;
        task(() -> {
            JSONObject profile = api.profile();
            JSONArray jobs = "approved".equals(profile.optString("driver_status","approved")) ? api.activeJobs() : new JSONArray();
            return new Panel(profile, jobs, jobs.length() == 0 && "approved".equals(profile.optString("driver_status","approved")) ? api.offers() : new JSONArray());
        }, panel -> {
            if (!visible) return;
            if (offerRouteDialog != null && !containsOffer(panel.offers(), previewedOfferId)) closeOfferRoute();
            screen = "home"; shell();
            if ("approved".equals(panel.profile().optString("driver_status","approved"))) PushManager.activate(this, api);
            text(root, "Hola, " + panel.profile().optString("full_name", "fletero"), 16, true);
            if (!"approved".equals(panel.profile().optString("driver_status","approved"))) {
                stopService(new Intent(this,TrackingService.class));PushManager.disableLocally(this);active=null;clearRoute();
                LinearLayout pending=card("pending".equals(panel.profile().optString("driver_status"))?"Cuenta pendiente de aprobación":"Cuenta no autorizada");
                text(pending,"Completa tu nombre, teléfono, vehículo y placas en Mi perfil. Administración debe revisar tu cuenta antes de que puedas recibir o aceptar servicios.",16,false);
                button(pending,"Completar mi perfil",this::profile);button(root,"Consultar aprobación",this::refresh);message.setText("");return;
            }
            if (panel.active().length() == 0 && PushManager.shouldRequestOnFirstUse(this)) {
                requestNoticePermission();
            }
            active = panel.active().length() == 1 ? panel.active().getJSONObject(0) : null;
            if (panel.active().length() > 1) {
                clearRoute();
                stopService(new Intent(this, TrackingService.class));
                text(card("Revisión necesaria"), "Hay más de un servicio activo. Contacta con administración antes de continuar.", 16, false);
                return;
            }
            if (active != null) {
                JSONObject job = active;
                LinearLayout box = card("Mi servicio actual");
                jobDetails(box, job);
                if ("accepted".equals(job.optString("status"))) {
                    text(box, "Confirmando el cobro con Stripe. Espera antes de iniciar la recogida.", 16, true);
                    button(root, "Actualizar panel", this::refresh);
                    message.setText("");
                    return;
                }
                boolean picked = "picked_up".equals(job.optString("status"));
                text(box, picked ? "Carga recogida · Lleva la carga al destino" : "En camino a recoger", 17, true);
                button(box, picked ? "Navegar al destino" : "Navegar al origen", () -> navigate(job, false));
                button(box, "Navegación guiada", () -> navigate(job, true));
                button(box,picked?"Llegué al punto de entrega":"Llegué al punto de recogida",()->new AlertDialog.Builder(appearance.context()).setTitle("¿Confirmar llegada?").setMessage("El cliente recibirá el aviso de tu llegada a este punto.").setNegativeButton("Volver",null).setPositiveButton("Confirmar llegada",(d,w)->task(()->{api.arrive(job.optString("id"),picked?"delivery":"pickup");return true;},ok->{message.setText("Llegada registrada. El cliente puede consultar el aviso.");})).show());
                button(box, picked ? "Completar servicio" : "Carga recogida", () -> confirmTransition(job, picked ? "completed" : "picked_up"));
                if (!picked && job.isNull("sandbox_payment_method")) button(box, "Liberar antes de recoger", () -> release(job));
                text(box, TrackingService.report(), 14, false);
                if (!trackingPermissionsGranted()) {
                    button(box, "Revisar permisos y activar ubicación", () -> requestTracking(null, true));
                } else if (!TrackingService.runningFor(job.optString("id"))) {
                    button(box, "Reintentar seguimiento", () -> requestTracking(null, true));
                }
                requestTracking(null, false);
                LinearLayout mapBox = card("Ruta de recogida a entrega");
                text(mapBox, "Referencia del servicio. Usa Navegar para recibir indicaciones desde tu ubicación.", 13, false);
                if (routeMap == null) routeMap = new RouteMapView(appearance.context(), api);
                if (routeMap.getParent() instanceof ViewGroup parent) parent.removeView(routeMap);
                mapBox.addView(routeMap);
                routeMap.show(job, api.userId());
                if (BuildConfig.NATIVE_ROUTE_MAP) {
                    button(mapBox, "Ver ruta en mapa", () -> task(() -> {
                        JSONObject route = api.route(job.getString("id"));
                        return route.has("points") ? RouteMapData.fromLongitudeFirst(route.getJSONArray("points"))
                            : RouteMapData.decode(route.getString("polyline"));
                    }, points -> RouteMapActivity.show(this, points)));
                }
            } else {
                clearRoute();
                stopService(new Intent(this, TrackingService.class));
                LinearLayout box = card("Solicitudes disponibles");
                if (panel.offers().length() == 0) text(box, "No hay nuevas solicitudes disponibles.", 16, false);
                for (int i = 0; i < panel.offers().length(); i++) {
                    JSONObject job = panel.offers().getJSONObject(i);
                    LinearLayout offer = card("Nueva solicitud"); jobDetails(offer, job);
                    button(offer, "Ver ruta de recogida a entrega", () -> previewOfferRoute(job.optString("id")));
                    button(offer, "Aceptar servicio", () -> requestTracking(job.optString("id"), true));
                }
                if (panel.offers().length() == 20) text(box, "Se muestran las 20 solicitudes más recientes.", 13, false);
            }
            button(root, "Actualizar panel", this::refresh);
            message.setText("");
        });
    }
    private void clearRoute() {
        if (routeMap != null) { routeMap.dispose(); routeMap = null; }
    }
    private boolean containsOffer(JSONArray offers, String id) {
        for (int i = 0; i < offers.length(); i++) {
            JSONObject offer = offers.optJSONObject(i);
            if (offer != null && id.equals(offer.optString("id"))) return true;
        }
        return false;
    }
    private void previewOfferRoute(String id) {
        task(() -> api.offerRoute(id), route -> {
            if (!visible || !"home".equals(screen) || active != null) return;
            RouteMapView map = new RouteMapView(appearance.context(), api);
            AlertDialog dialog = new AlertDialog.Builder(appearance.context()).setTitle("Ruta estimada del servicio")
                .setView(map).setPositiveButton("Cerrar", null).create();
            offerRouteDialog = dialog;
            previewedOfferId = id;
            dialog.setOnDismissListener(ignored -> {
                map.dispose();
                if (offerRouteDialog == dialog) {
                    offerRouteDialog = null;
                    previewedOfferId = "";
                }
            });
            dialog.show();
            map.showCalculatedRoute(route, false);
        });
    }
    private void closeOfferRoute() {
        if (offerRouteDialog != null) offerRouteDialog.dismiss();
    }
    private void showAppearance() {
        clearRoute();
        screen = "appearance";
        shell();
        var box = card("Apariencia");
        appearance.addChoices(box, this::showAppearance);
        button(root, "Volver al panel", () -> {
            screen = "home";
            shell();
            refresh();
        }, false);
    }
    private void showMenu(View anchor) {
        PopupMenu menu = new PopupMenu(appearance.context(), anchor);
        menu.getMenu().add(0, 1, 0, "Mi servicio / Solicitudes");
        menu.getMenu().add(0, 2, 1, "Mi perfil");
        menu.getMenu().add(0, 3, 2, "Mis servicios completados");
        if (BuildConfig.PUSH_ENABLED) menu.getMenu().add(0, 4, 3, "Avisos de solicitudes");
        menu.getMenu().add(0, 6, 4, "Comisión en efectivo");
        menu.getMenu().add(0, 7, 5, "Apariencia");
        menu.getMenu().add(0, 5, 6, "Cerrar sesión");
        menu.setOnMenuItemClickListener(item -> {
            if (busy) return true;
            switch (item.getItemId()) {
                case 1 -> { screen = "home"; refresh(); }
                case 2 -> profile();
                case 3 -> { screen = "history"; historyPage = 0; history(); }
                case 4 -> new AlertDialog.Builder(appearance.context()).setTitle("Avisos de solicitudes")
                    .setMessage(PushManager.report()).setNegativeButton("Volver", null)
                    .setPositiveButton("Activar avisos", (d, w) -> {
                        if (PushManager.shouldRequestOnFirstUse(this)
                            || (Build.VERSION.SDK_INT >= 33 && shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS))) {
                            requestNoticePermission();
                        }
                        else if (!PushManager.permitted(this)) open("package:" + getPackageName(), android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
                        else { PushManager.tokenChanged(this, api); message.setText(PushManager.report()); }
                    }).show();
                case 6 -> showCashCommissionCuts();
                case 7 -> showAppearance();
                case 5 -> confirmLogout();
                default -> { return false; }
            }
            return true;
        });
        menu.show();
    }
    private void jobDetails(LinearLayout box, JSONObject job) {
        text(box, "Recogida: " + job.optString("origin"), 16, true);
        text(box, "Entrega: " + job.optString("destination"), 16, true);
        text(box, job.optString("service_type", "Flete") + " · " + vehicleLabel(job.optString("vehicle_type")), 15, false);
        text(box, job.optString("distance_km", "—") + " km · Ayudantes: " + job.optInt("helpers"), 15, false);
        NumberFormat money = NumberFormat.getCurrencyInstance(Locale.forLanguageTag("es-MX"));
        text(box, money.format(job.optDouble("price", 0)) + " MXN", 24, true).setTextColor(appearance.accent());
        if ("cash".equals(job.optString("payment_method"))) {
            text(box, "Cobras en efectivo al entregar", 16, true);
        }
        if (!job.isNull("sandbox_payment_method")) {
            text(box, "Tarjeta de prueba · No cobrar efectivo ni esperar transferencia real", 16, true);
        }
        if (BuildConfig.TEST_ROUTE_PRICING && !job.isNull("test_driver_payout")) {
            text(box, (job.isNull("sandbox_payment_method") ? "Recibes " : "Neto simulado ") + money.format(job.optDouble("test_driver_payout")) + " MXN", 16, true);
        }
    }
    private String vehicleLabel(String value) {
        return switch (value) { case "pickup" -> "Camioneta pickup"; case "estaquita_abierta" -> "Estaquita abierta"; case "estaquita_caja_seca" -> "Estaquita caja seca"; case "camion_3_5t" -> "Camión 3.5 t"; case "camioneta" -> "Camioneta (registro anterior)"; case "camion" -> "Camión (registro anterior)"; default -> "Sin registrar"; };
    }
    private void requestNoticePermission() {
        PushManager.markPermissionRequested(this);
        requestingNotices = true;
        requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 18);
    }
    private boolean preciseLocationGranted() {
        return checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }
    private boolean noticePermissionGranted() {
        return Build.VERSION.SDK_INT < 33
            || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED;
    }
    private boolean trackingPermissionsGranted() {
        return preciseLocationGranted() && noticePermissionGranted();
    }
    private void requestTracking(String acceptingId, boolean explicit) {
        if (!visible) return;
        if (acceptingId == null && active == null) return;
        if (acceptingId == null && TrackingService.runningFor(active.optString("id"))) return;
        if (trackingPermissionsGranted()) { afterPermissions(acceptingId); return; }
        if (!explicit) return;
        new AlertDialog.Builder(appearance.context()).setTitle("Ubicación durante tu servicio")
            .setMessage("FLETYA compartirá tu ubicación con el cliente del servicio activo, incluso mientras usas Google Maps o apagas la pantalla. Verás un aviso de seguimiento. Se detendrá al completar, liberar el servicio o cerrar sesión. Se te pedirán los permisos pendientes.")
            .setPositiveButton("Continuar", (dialog, which) -> {
                permissionAcceptId = acceptingId;
                var missing = new java.util.ArrayList<String>();
                if (!preciseLocationGranted()) {
                    missing.add(Manifest.permission.ACCESS_FINE_LOCATION);
                    missing.add(Manifest.permission.ACCESS_COARSE_LOCATION);
                }
                if (!noticePermissionGranted()) {
                    PushManager.markPermissionRequested(this);
                    missing.add(Manifest.permission.POST_NOTIFICATIONS);
                }
                if (missing.isEmpty()) afterPermissions(acceptingId);
                else requestPermissions(missing.toArray(new String[0]), 17);
            }).setNegativeButton("Ahora no", null).show();
    }
    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(requestCode, permissions, results);
        if (requestCode == 18) {
            requestingNotices = false;
            if (api.signedIn()) { PushManager.activate(this, api); refresh(); }
            return;
        }
        if (!api.signedIn()) return;
        if (requestCode != 17) return;
        String acceptingId = permissionAcceptId; permissionAcceptId = null;
        if (trackingPermissionsGranted()) afterPermissions(acceptingId);
        else {
            message.setText("Se necesita ubicación precisa y notificaciones para activar el seguimiento.");
            new AlertDialog.Builder(appearance.context()).setMessage("Puedes habilitar los permisos desde los ajustes de esta app.")
                .setPositiveButton("Abrir ajustes", (d, w) -> open("package:" + getPackageName(), android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS))
                .setNegativeButton("Cerrar", null).show();
        }
    }
    private void afterPermissions(String acceptingId) {
        if (acceptingId != null) {
            new AlertDialog.Builder(appearance.context()).setTitle("¿Aceptar este servicio?")
                .setMessage("Al aceptar comenzarás a compartir ubicación para recoger y entregar la carga.")
                .setPositiveButton("Aceptar", (d, w) -> task(() -> api.acceptOffer(acceptingId), job -> {
                    active = job; startTracker(); refresh();
                })).setNegativeButton("Cancelar", null).show();
        } else startTracker();
    }
    private void startTracker() {
        if (!visible || active == null || !api.signedIn()
            || !DriverRules.ownsActive(active.optString("status"), active.optString("driver_id"), api.userId())) return;
        if (!TrackingService.runningFor(active.optString("id"))) {
            try { startForegroundService(new Intent(this, TrackingService.class).putExtra("job_id", active.optString("id"))); }
            catch (RuntimeException error) { message.setText("No se pudo iniciar el seguimiento. Revisa los permisos y vuelve a intentar."); }
        }
    }
    private void showCashCommissionCuts() {
        task(api::cashCommissionCuts, cuts -> {
            screen = "cash-cuts";
            shell();
            LinearLayout header = card("Comisión en efectivo");
            text(header, "El corte cierra el domingo y se paga hasta el martes siguiente.", 15, false);
            if (cuts.length() == 0) text(header, "Aún no tienes comisiones en efectivo.", 15, false);
            NumberFormat money = NumberFormat.getCurrencyInstance(Locale.forLanguageTag("es-MX"));
            for (int i = 0; i < cuts.length(); i++) {
                JSONObject cut = cuts.getJSONObject(i);
                String state = cut.optInt("pending_count") == 0 ? "Pagado" : cut.optBoolean("closed") ? "Cerrado" : "En curso";
                LinearLayout box = card("Semana del " + cut.optString("week_start") + " · " + state);
                text(box, "Pendiente: " + money.format(cut.optLong("pending_cents") / 100.0) + " MXN", 16, true);
                text(box, "Fecha límite: " + cut.optString("due_on"), 15, false);
                if (cut.optBoolean("closed") && cut.optInt("pending_count") > 0) {
                    JSONObject account = cut.optJSONObject("spei_account");
                    String reference = cut.optString("spei_reference", "");
                    if (account == null || reference.isEmpty()) {
                        text(box, "Los datos para transferir aún no están disponibles.", 15, false);
                    } else {
                        String clabe = account.getString("clabe");
                        text(box, "Transferencia SPEI · " + account.getString("bank"), 16, true);
                        text(box, "Beneficiario: " + account.getString("beneficiary"), 15, false);
                        text(box, "CLABE: " + clabe, 15, false);
                        text(box, "Referencia SPEI: " + reference, 15, false);
                        button(box, "Copiar CLABE", () -> copyPaymentField("CLABE", clabe));
                        button(box, "Copiar referencia", () -> copyPaymentField("Referencia SPEI", reference));
                    }
                }
                JSONArray jobs = cut.getJSONArray("jobs");
                for (int j = 0; j < jobs.length(); j++) {
                    JSONObject job = jobs.getJSONObject(j);
                    text(box, job.optString("date") + " · " + money.format(job.optLong("commission_cents") / 100.0)
                        + " · " + (job.optBoolean("settled") ? "Pagado" : "Pendiente")
                        + "\n" + job.optString("id"), 14, false);
                }
            }
            button(root, "Actualizar cortes", this::showCashCommissionCuts);
            button(root, "Volver al panel", () -> { screen = "home"; refresh(); });
            message.setText("");
        });
    }

    private void copyPaymentField(String label, String value) {
        ClipboardManager clipboard = getSystemService(ClipboardManager.class);
        clipboard.setPrimaryClip(ClipData.newPlainText(label, value));
        message.setText(label + " copiada.");
    }

    private void confirmTransition(JSONObject job, String next) {
        boolean complete = "completed".equals(next);
        boolean cash = complete && "cash".equals(job.optString("payment_method"));
        String id = job.optString("id");
        AlertDialog.Builder dialog = new AlertDialog.Builder(appearance.context())
            .setTitle(cash ? "¿Recibiste el efectivo?" : complete ? "¿Completaste la entrega?" : "¿Ya recogiste la carga?")
            .setMessage(cash ? "Confirma cuando hayas entregado la carga y recibido el efectivo completo."
                : complete ? "El servicio quedará completado y dejarás de compartir ubicación."
                : "Después de confirmar la recogida ya no podrás liberar el servicio.")
            .setPositiveButton(cash ? "Sí, recibí el efectivo" : "Confirmar", (d, w) -> task(
                () -> cash ? api.completeCashDelivery(id) : api.transition(id, job.optString("status"), next, null), updated -> {
                    if (complete) { stopService(new Intent(this, TrackingService.class)); active = null; }
                    else active = updated;
                    refresh();
                }))
            .setNegativeButton("Cancelar", null);
        if (cash) dialog.setNeutralButton("Reportar falta de pago", (d, w) ->
            task(() -> { api.reportCashCollectionIssue(id); return true; },
                ignored -> message.setText("Avisaste a Administración. El servicio sigue abierto.")));
        dialog.show();
    }
    private void release(JSONObject job) {
        EditText reason = new EditText(appearance.context()); appearance.styleField(reason); reason.setHint("Motivo de 10 a 300 caracteres"); reason.setMinLines(2);
        AlertDialog dialog = new AlertDialog.Builder(appearance.context()).setTitle("Liberar antes de recoger").setView(reason)
            .setPositiveButton("Liberar servicio", null).setNegativeButton("Cancelar", null).create();
        dialog.setOnShowListener(ignored -> dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(view -> {
            String value = reason.getText().toString().trim();
            if (!DriverRules.validReason(value)) { reason.setError("Escribe entre 10 y 300 caracteres."); return; }
            dialog.dismiss();
            task(() -> api.transition(job.optString("id"), "en_route", "requested", value), updated -> {
                stopService(new Intent(this, TrackingService.class)); active = null; refresh();
            });
        })); dialog.show();
    }
    private void navigate(JSONObject job, boolean guided) {
        String id = job.optString("id");
        String status = job.optString("status");
        var fix = TrackingService.recentNavigationFix(id);
        if (fix == null) {
            message.setText("Espera una ubicación GPS reciente y vuelve a tocar Navegar.");
            requestTracking(null, false);
            return;
        }
        String origin = fix.getLatitude() + "," + fix.getLongitude();
        task(() -> {
            try { return api.navigationRoute(id, status, origin, guided); }
            catch (DriverApi.Failure error) {
                if (guided && error.status == 422) return new JSONObject().put("guidance_error", true);
                throw error;
            }
        }, route -> {
            if (!visible || active == null || !id.equals(active.optString("id")) || !status.equals(active.optString("status"))) return;
            if (guided) {
                if (route.optBoolean("guidance_error")) {
                    new AlertDialog.Builder(appearance.context()).setTitle("Navegación no disponible")
                        .setMessage("No se pudo verificar la ruta guiada. Comprueba que el destino de esta etapa se seleccionó mediante un pin en el mapa.")
                        .setPositiveButton("Entendido", null).show();
                    return;
                }
                var steps = route.optJSONArray("navigation_steps");
                if (steps == null || steps.length() == 0) {
                    message.setText("La guía de giros no está disponible para esta ruta.");
                    return;
                }
                GuidedNavigationActivity.show(this, id, api.userId(), status, route);
                return;
            }
            if ("external".equals(route.optString("navigation_mode"))) {
                open("https://www.google.com/maps/dir/?api=1&travelmode=driving&dir_action=navigate&destination="
                    + Uri.encode(route.getString("navigation_destination")));
                return;
            }
            RouteMapView map = new RouteMapView(appearance.context(), api);
            AlertDialog dialog = new AlertDialog.Builder(appearance.context()).setTitle("Ruta para carga")
                .setView(map).setPositiveButton("Cerrar", null).create();
            dialog.setOnDismissListener(ignored -> map.dispose());
            dialog.show();
            map.showNavigation(route);
        });
    }
    private void open(String uri) { open(uri, Intent.ACTION_VIEW); }
    private void open(String uri, String action) {
        try { startActivity(new Intent(action, Uri.parse(uri))); }
        catch (ActivityNotFoundException error) { message.setText("No se encontró una aplicación para abrir el enlace."); }
    }
    private void profile() {
        task(api::profile, profile -> {
            screen = "profile"; shell();
            LinearLayout box = card("Mi perfil de fletero");
            EditText name = field(box, "Nombre completo", profile.optString("full_name"), InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_CAP_WORDS);
            text(box, "Vehículo", 14, true);
            Spinner vehicles = new Spinner(appearance.context());
            vehicles.setAdapter(new ArrayAdapter<>(appearance.context(), android.R.layout.simple_spinner_dropdown_item, new String[]{"Elige tu vehículo", "Camioneta pickup", "Estaquita abierta", "Estaquita caja seca", "Camión 3.5 t", "Camioneta (anterior)", "Camión (anterior)"}));
            String[] codes = {"", "pickup", "estaquita_abierta", "estaquita_caja_seca", "camion_3_5t", "camioneta", "camion"};
            for (int i = 0; i < codes.length; i++) if (codes[i].equals(profile.optString("vehicle_type"))) vehicles.setSelection(i);
            box.addView(vehicles, new LinearLayout.LayoutParams(-1, dp(52)));
            EditText phone = field(box,"Teléfono con lada",profile.isNull("phone")?"":profile.optString("phone"),InputType.TYPE_CLASS_PHONE);
            EditText plates = field(box, "Placas", profile.isNull("plates") ? "" : profile.optString("plates"), InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS);
            button(box, "Guardar perfil", () -> {
                String fullName = name.getText().toString(); String vehicle = codes[vehicles.getSelectedItemPosition()]; String plate = plates.getText().toString(); String telephone=phone.getText().toString().trim();
                task(() -> { api.saveProfile(fullName, vehicle, plate,telephone); return true; }, result -> message.setText("Perfil guardado."));
            });
            if ("PRUEBAS".equals(BuildConfig.ENVIRONMENT)) {
                text(box, "Capacidad útil y espacio de carga (sujetos a verificación de Admin)", 14, true);
                EditText payload = field(box, "Carga útil máxima (kg)", profile.isNull("vehicle_payload_kg") ? "" : profile.optString("vehicle_payload_kg"), InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_DECIMAL);
                EditText length = field(box, "Largo interior (cm)", profile.isNull("vehicle_cargo_length_cm") ? "" : profile.optString("vehicle_cargo_length_cm"), InputType.TYPE_CLASS_NUMBER);
                EditText width = field(box, "Ancho interior (cm)", profile.isNull("vehicle_cargo_width_cm") ? "" : profile.optString("vehicle_cargo_width_cm"), InputType.TYPE_CLASS_NUMBER);
                EditText height = field(box, "Alto útil (cm)", profile.isNull("vehicle_cargo_height_cm") ? "" : profile.optString("vehicle_cargo_height_cm"), InputType.TYPE_CLASS_NUMBER);
                button(box, "Guardar capacidad y medidas", () -> task(() -> {
                    api.saveVehicleCapacity(payload.getText().toString(), length.getText().toString(), width.getText().toString(), height.getText().toString());
                    return true;
                }, result -> message.setText("Medidas guardadas. Pendientes de verificación por Admin.")));
            }
            button(root, "Volver al servicio", () -> { screen = "home"; refresh(); });
            message.setText("");
        });
    }
    private void history() {
        int page = historyPage;
        task(() -> api.history(page * 5), rows -> {
            screen = "history"; shell(); card("Mis servicios completados");
            for (int i = 0; i < Math.min(5, rows.length()); i++) {
                JSONObject job = rows.getJSONObject(i);
                LinearLayout box = card("Completado"); jobDetails(box, job);
                text(box, job.optString("created_at").split("T")[0], 13, false);
            }
            if (rows.length() == 0) text(root, "No hay servicios en esta página.", 16, false);
            text(root, "Página " + (page + 1), 14, false);
            if (page > 0) button(root, "Anterior", () -> { historyPage--; history(); });
            if (rows.length() > 5) button(root, "Ver más", () -> { historyPage++; history(); });
            button(root, "Volver al servicio", () -> { screen = "home"; refresh(); });
            message.setText("");
        });
    }
    private void confirmLogout() {
        new AlertDialog.Builder(appearance.context()).setTitle("¿Cerrar sesión?").setMessage(active == null ? "Tendrás que iniciar sesión de nuevo para usar la app." : "Dejarás de compartir ubicación. El servicio seguirá asignado a tu cuenta.")
            .setPositiveButton("Cerrar sesión", (d, w) -> {
                stopService(new Intent(this, TrackingService.class));
                String[] registration = PushManager.disableLocally(this);
                task(() -> {
                    try { api.unregisterPush(registration[0], registration[1]); } catch (Exception ignored) { /* Local nonce already invalid. */ }
                    api.logout(); return true;
                }, result -> { revision++; active = null; loginScreen(); });
            }).setNegativeButton("Cancelar", null).show();
    }
}
