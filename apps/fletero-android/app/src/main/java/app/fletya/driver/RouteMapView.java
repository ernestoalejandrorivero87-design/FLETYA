package app.fletya.driver;

import android.annotation.SuppressLint;
import android.content.Context;
import android.graphics.Color;
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
    private String key = "", jobId = "", owner = "";
    private long generation;
    private boolean disposed;
    RouteMapView(Context context, DriverApi api) {
        super(context); this.api = api; setOrientation(VERTICAL);
        status = new TextView(context); status.setTextColor(Color.DKGRAY); addView(status);
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
        status.setText("Cargando ruta…"); retry.setVisibility(GONE); clearMap();
        worker.execute(() -> {
            try {
                JSONObject route = api.route(requestedId);
                String coordinates = RouteMapData.decode(route.optString("polyline")).toString();
                String css = asset("leaflet.css"), js = asset("leaflet.js");
                String detail = route.optString("distance_km", "—") + " km · " + route.optString("duration_text", "");
                post(() -> {
                    if (disposed || generation != request || !requestedOwner.equals(api.userId())) return;
                    try { render(css, js, coordinates); status.setText(detail); }
                    catch (RuntimeException error) { clearMap(); status.setText("No se pudo abrir el mapa. Puedes usar Navegar."); retry.setVisibility(VISIBLE); }
                });
            } catch (Exception error) {
                post(() -> {
                    if (disposed || generation != request || !requestedOwner.equals(api.userId())) return;
                    status.setText("No se pudo cargar la ruta. Revisa tu conexión o usa Navegar."); retry.setVisibility(VISIBLE);
                });
            }
        });
    }
    private String asset(String name) throws Exception {
        try (var input = getContext().getAssets().open(name)) { var output = new java.io.ByteArrayOutputStream(); byte[] buffer = new byte[8192]; int count; while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count); return output.toString(StandardCharsets.UTF_8.name()); }
    }
    @SuppressLint({"SetJavaScriptEnabled", "ClickableViewAccessibility"})
    private void render(String css, String js, String points) {
        map = new WebView(getContext());
        map.getSettings().setJavaScriptEnabled(true);
        map.getSettings().setAllowFileAccess(false); map.getSettings().setAllowContentAccess(false);
        map.getSettings().setGeolocationEnabled(false);
        map.getSettings().setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        map.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) { return true; }
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
        addView(map, new LayoutParams(-1, Math.round(270 * getResources().getDisplayMetrics().density)));
        String html = "<!doctype html><html lang='es'><meta name='viewport' content='width=device-width,initial-scale=1'>"
            + "<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; img-src https://tile.openstreetmap.org data:; style-src 'unsafe-inline'; script-src 'unsafe-inline';\">"
            + "<style>" + css + "html,body,#map{height:100%;margin:0}#notice{position:absolute;bottom:24px;left:8px;z-index:999;background:white;font:12px sans-serif;padding:4px}</style>"
            + "<div id='map' aria-label='Ruta del servicio'></div><div id='notice' hidden>Mapa base sin conexión. Usa Navegar o reintenta el mapa.</div><script>" + js
            + "const points=" + points + ";const map=L.map('map',{scrollWheelZoom:false});"
            + "L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:19,attribution:'&copy; OpenStreetMap contributors'}).on('tileerror',()=>document.getElementById('notice').hidden=false).addTo(map);"
            + "const line=L.polyline(points,{color:'#087f88',weight:5}).addTo(map);map.fitBounds(line.getBounds(),{padding:[25,25]});"
            + "L.circleMarker(points[0],{radius:8,color:'#087f88',fillOpacity:1}).addTo(map).bindTooltip('Recogida');"
            + "L.circleMarker(points[points.length-1],{radius:8,color:'#c85229',fillOpacity:1}).addTo(map).bindTooltip('Entrega');</script></html>";
        map.loadDataWithBaseURL("https://fletya.vercel.app/", html, "text/html", "UTF-8", null);
    }
    private void clearMap() {
        if (map != null) { removeView(map); map.stopLoading(); map.destroy(); map = null; }
    }
    void dispose() { disposed = true; generation++; worker.shutdownNow(); clearMap(); }
}
