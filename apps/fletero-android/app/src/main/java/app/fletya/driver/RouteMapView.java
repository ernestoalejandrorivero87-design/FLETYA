package app.fletya.driver;

import android.annotation.SuppressLint;
import android.content.Context;
import android.location.Location;
import android.webkit.*;
import android.view.MotionEvent;
import android.widget.*;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.io.ByteArrayInputStream;
import java.util.concurrent.*;

/** Reused across panel refreshes. No session, addresses, remote scripts or JS bridge in WebView. */
final class RouteMapView extends LinearLayout {
    private final DriverApi api;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final TextView status;
    private final Button retry;
    private WebView map;
    private Location guidedFix;
    private String key = "", jobId = "", owner = "";
    private long generation;
    private boolean disposed;
    RouteMapView(Context context, DriverApi api) {
        super(context); this.api = api; setOrientation(VERTICAL);
        status = new TextView(context); addView(status);
        retry = new Button(context); retry.setText("Reintentar mapa"); retry.setAllCaps(false);
        retry.setOnClickListener(v -> load()); addView(retry); retry.setVisibility(GONE);
    }
    void show(JSONObject job, String user) {
        String next = user + "|" + job.optString("id") + "|" + job.optString("origin") + "|" + job.optString("destination");
        if (next.equals(key) || disposed) return;
        key = next; jobId = job.optString("id"); owner = user; load();
    }
    private void load() {
        if (disposed || worker.isShutdown()) return;
        long request = ++generation;
        String requestedId = jobId, requestedOwner = owner;
        status.setText("Cargando ruta…"); retry.setText("Reintentar mapa"); retry.setVisibility(GONE); clearMap();
        worker.execute(() -> {
            try {
                JSONObject route = api.route(requestedId);
                String coordinates = (route.has("points") ? RouteMapData.fromLongitudeFirst(route.getJSONArray("points"))
                    : RouteMapData.decode(route.getString("polyline"))).toString();
                String css = asset("leaflet.css"), js = asset("leaflet.js");
                String detail = route.optString("distance_km", "—") + " km · " + route.optString("duration_text", "");
                post(() -> {
                    if (disposed || generation != request || !requestedOwner.equals(api.userId())) return;
                    try { render(css, js, coordinates, false, false); status.setText(detail); retry.setText("Recargar mapa"); retry.setVisibility(VISIBLE); }
                    catch (RuntimeException error) { clearMap(); status.setText("No se pudo abrir el mapa. Reintenta."); retry.setVisibility(VISIBLE); }
                });
            } catch (Exception error) {
                post(() -> {
                    if (disposed || generation != request || !requestedOwner.equals(api.userId())) return;
                    status.setText("No se pudo cargar la ruta. Revisa tu conexión y reintenta."); retry.setVisibility(VISIBLE);
                });
            }
        });
    }
    void showNavigation(JSONObject route) {
        worker.execute(() -> {
            try {
                String coordinates = RouteMapData.decode(route.getString("polyline")).toString();
                String css = asset("leaflet.css"), js = asset("leaflet.js");
                post(() -> {
                    if (disposed) return;
                    try {
                        render(css, js, coordinates, true, false);
                        status.setText(route.optString("distance_km") + " km · " + route.optString("duration_text")
                            + "\nSigue la línea marcada. Ruta para carga sin cruzar el Puente Nichupté.");
                    } catch (RuntimeException failure) {
                        clearMap();
                        status.setText("No se pudo abrir la ruta. Cierra y vuelve a calcularla.");
                    }
                });
            } catch (Exception failure) {
                post(() -> { if (!disposed) status.setText("No se pudo mostrar la ruta. Cierra y vuelve a calcularla."); });
            }
        });
    }
    void showGuidedRoute(org.json.JSONArray points) {
        status.setText("Cargando mapa…");
        String coordinates = points.toString();
        worker.execute(() -> {
            try {
                String css = asset("leaflet.css"), js = asset("leaflet.js");
                post(() -> {
                    if (disposed) return;
                    try { render(css, js, coordinates, true, true); status.setVisibility(GONE); }
                    catch (RuntimeException error) { clearMap(); status.setText("No se pudo abrir el mapa guiado."); }
                });
            } catch (Exception error) {
                post(() -> { if (!disposed) status.setText("No se pudo cargar el mapa guiado."); });
            }
        });
    }
    void updateVehicle(Location fix) {
        guidedFix = fix;
        if (map == null || disposed) return;
        String point = fix == null ? "null" : "[" + fix.getLatitude() + "," + fix.getLongitude() + "]";
        map.evaluateJavascript("if (window.updateVehicle) window.updateVehicle(" + point + ")", null);
    }
    private String asset(String name) throws Exception {
        try (var input = getContext().getAssets().open(name)) { var output = new java.io.ByteArrayOutputStream(); byte[] buffer = new byte[8192]; int count; while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count); return output.toString(StandardCharsets.UTF_8.name()); }
    }
    @SuppressLint({"SetJavaScriptEnabled", "ClickableViewAccessibility"})
    private void render(String css, String js, String points, boolean navigation, boolean guided) {
        map = new WebView(getContext());
        map.getSettings().setJavaScriptEnabled(true);
        map.getSettings().setAllowFileAccess(false); map.getSettings().setAllowContentAccess(false);
        map.getSettings().setGeolocationEnabled(false);
        map.getSettings().setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        map.setWebViewClient(new WebViewClient() {
            @Override public void onPageFinished(WebView view, String url) {
                if (guided && view == map) updateVehicle(guidedFix);
            }
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                if (request.hasGesture() && "https://www.openstreetmap.org/copyright".equals(request.getUrl().toString())) {
                    try { getContext().startActivity(new android.content.Intent(android.content.Intent.ACTION_VIEW, request.getUrl())); }
                    catch (android.content.ActivityNotFoundException ignored) { /* Attribution text remains visible. */ }
                }
                return true;
            }
            @Override public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                android.net.Uri url = request.getUrl();
                if ("https".equals(url.getScheme()) && "tile.openstreetmap.org".equals(url.getHost()) && "GET".equals(request.getMethod()) && url.getPath() != null && url.getPath().matches("/\\d+/\\d+/\\d+\\.png")) return null;
                return new WebResourceResponse("text/plain", "UTF-8", new ByteArrayInputStream(new byte[0]));
            }
        });
        map.setOnTouchListener((view, event) -> {
            if (view.getParent() != null) view.getParent().requestDisallowInterceptTouchEvent(event.getActionMasked() != MotionEvent.ACTION_UP && event.getActionMasked() != MotionEvent.ACTION_CANCEL);
            return false;
        });
        addView(map, guided ? new LayoutParams(-1, 0, 1)
            : new LayoutParams(-1, Math.round(270 * getResources().getDisplayMetrics().density)));
        String html = "<!doctype html><html lang='es'><meta name='viewport' content='width=device-width,initial-scale=1'>"
            + "<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; img-src https://tile.openstreetmap.org data:; style-src 'unsafe-inline'; script-src 'unsafe-inline';\">"
            + "<style>" + css + "html,body,#map{height:100%;margin:0}#notice{position:absolute;bottom:24px;left:8px;z-index:999;background:white;font:12px sans-serif;padding:4px}</style>"
            + "<div id='map' aria-label='Ruta del servicio'></div><div id='notice' hidden>Mapa base sin conexión. Reintenta al recuperar la señal.</div><script>" + js
            + "\nconst points=" + points + ";const map=L.map('map',{scrollWheelZoom:false});"
            + "L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:19,attribution:'&copy; <a href=\"https://www.openstreetmap.org/copyright\">OpenStreetMap</a> contributors'}).on('tileerror',()=>document.getElementById('notice').hidden=false).addTo(map);"
            + "const line=L.polyline(points,{color:'#881A42',weight:5}).addTo(map);map.fitBounds(line.getBounds(),{padding:[25,25]});"
            + (guided ? "let vehicle;window.updateVehicle=p=>{if(!p){if(vehicle){vehicle.remove();vehicle=null;}return;}"
                + "if(vehicle){vehicle.setLatLng(p);map.panTo(p,{animate:false});}"
                + "else{vehicle=L.circleMarker(p,{radius:9,color:'#1264ce',fillOpacity:1}).addTo(map);map.setView(p,16);}};"
                : "L.circleMarker(points[0],{radius:8,color:'#087f88',fillOpacity:1}).addTo(map).bindTooltip('" + (navigation ? "Tu ubicación" : "Recogida") + "');")
            + "L.circleMarker(points[points.length-1],{radius:8,color:'#c85229',fillOpacity:1}).addTo(map).bindTooltip('" + (navigation ? "Destino de esta etapa" : "Entrega") + "');</script></html>";
        map.loadDataWithBaseURL("https://fletya.vercel.app/", html, "text/html", "UTF-8", null);
    }
    private void clearMap() {
        if (map != null) { removeView(map); map.stopLoading(); map.destroy(); map = null; }
    }
    void dispose() { disposed = true; generation++; worker.shutdownNow(); clearMap(); }
}
