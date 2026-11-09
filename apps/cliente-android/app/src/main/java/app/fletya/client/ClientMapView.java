package app.fletya.client;

import android.annotation.SuppressLint;
import android.content.Context;
import android.webkit.*;
import android.view.MotionEvent;
import org.json.*;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;

/** Bundled map code only. Coordinates cross evaluateJavascript; no JavaScript/native bridge or tokens. */
@SuppressLint({"SetJavaScriptEnabled", "ClickableViewAccessibility"})
final class ClientMapView extends WebView {
    interface Selection { void receive(double lat,double lng); }
    private boolean ready, disposed;
    private JSONObject fix;
    private String currentPolyline = "";
    ClientMapView(Context context) {
        super(context);
        getSettings().setJavaScriptEnabled(true);
        getSettings().setAllowFileAccess(false); getSettings().setAllowContentAccess(false);
        getSettings().setGeolocationEnabled(false); getSettings().setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        setWebViewClient(new WebViewClient() {
            @Override public void onPageFinished(WebView view,String url) { if (!disposed) { ready = true; updateDriver(fix); } }
            @Override public boolean shouldOverrideUrlLoading(WebView view,WebResourceRequest request) {
                if (request.hasGesture() && "https://www.openstreetmap.org/copyright".equals(request.getUrl().toString())) {
                    try { context.startActivity(new android.content.Intent(android.content.Intent.ACTION_VIEW,request.getUrl())); }
                    catch (android.content.ActivityNotFoundException ignored) { /* Keep attribution visible. */ }
                }
                return true;
            }
            @Override public WebResourceResponse shouldInterceptRequest(WebView view,WebResourceRequest request) {
                var url = request.getUrl();
                if ("https".equals(url.getScheme()) && "tile.openstreetmap.org".equals(url.getHost()) && "GET".equals(request.getMethod()) && url.getPath()!=null && url.getPath().matches("/\\d+/\\d+/\\d+\\.png")) return null;
                return new WebResourceResponse("text/plain","UTF-8",new ByteArrayInputStream(new byte[0]));
            }
        });
        setOnTouchListener((view,event) -> {
            if (view.getParent()!=null) view.getParent().requestDisallowInterceptTouchEvent(event.getActionMasked()!=MotionEvent.ACTION_UP && event.getActionMasked()!=MotionEvent.ACTION_CANCEL);
            return false;
        });
    }
    private String asset(String name) throws Exception {
        try(var input=getContext().getAssets().open(name)) {
            var out=new java.io.ByteArrayOutputStream(); byte[] data=new byte[8192];int count;
            while((count=input.read(data))!=-1) out.write(data,0,count);
            return out.toString(StandardCharsets.UTF_8.name());
        }
    }
    private void page(String code) throws Exception {
        ready=false;
        String html="<!doctype html><html lang='es'><meta name='viewport' content='width=device-width,initial-scale=1'>"
            +"<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; img-src https://tile.openstreetmap.org data:; style-src 'unsafe-inline'; script-src 'unsafe-inline';\">"
            +"<style>"+asset("leaflet.css")+"html,body,#map{height:100%;margin:0}#notice{position:absolute;bottom:24px;left:6px;z-index:999;background:white;font:12px sans-serif;padding:4px}.pin{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);z-index:900;color:#c85229;font:38px sans-serif;pointer-events:none}</style>"
            +"<div id='map' aria-label='Mapa FLETYA'></div><div id='notice' hidden>Mapa base sin conexión. Revisa internet.</div><script>"+asset("leaflet.js")+"\n"
            +"window.map=L.map('map',{scrollWheelZoom:false});L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:19,attribution:'&copy; <a href=\"https://www.openstreetmap.org/copyright\">OpenStreetMap</a> contributors'}).on('tileerror',()=>document.getElementById('notice').hidden=false).addTo(map);"
            +"window.driver=null;window.setDriver=function(p){if(driver){map.removeLayer(driver);driver=null}if(p)driver=L.circleMarker([p.lat,p.lng],{radius:9,color:p.fresh?'#215be8':'#b56a12',fillOpacity:1}).addTo(map).bindTooltip('Fletero')};"
            +code+"</script></html>";
        loadDataWithBaseURL("https://fletya.vercel.app/",html,"text/html","UTF-8",null);
    }
    void picker(double[] initial) throws Exception {
        double lat=initial==null?21.1619:initial[0],lng=initial==null?-86.8515:initial[1];
        page("map.setView(["+lat+","+lng+"],15);map.on('click',e=>map.panTo(e.latlng));window.getSelectedPoint=()=>({lat:map.getCenter().lat,lng:map.getCenter().lng});document.body.insertAdjacentHTML('beforeend','<div class=\"pin\">⊕</div>');");
    }
    void selected(Selection callback,Runnable failed) {
        if (!ready || disposed) { failed.run();return; }
        evaluateJavascript("typeof getSelectedPoint==='function'?getSelectedPoint():null",value->{
            if (disposed) return;
            try { JSONObject p=new JSONObject(value);double lat=p.getDouble("lat"),lng=p.getDouble("lng");if(!ClientRules.validPoint(lat,lng))throw new IllegalArgumentException();callback.receive(lat,lng); }
            catch(Exception error){failed.run();}
        });
    }
    void route(String polyline) throws Exception {
        if (disposed || polyline.equals(currentPolyline)) return;
        String points=RouteMapData.decode(polyline).toString();
        page("const p="+points+";const route=L.polyline(p,{color:'#087f88',weight:5}).addTo(map);map.fitBounds(route.getBounds(),{padding:[24,24]});L.circleMarker(p[0],{color:'#087f88',radius:7,fillOpacity:1}).addTo(map).bindTooltip('Recogida');L.circleMarker(p[p.length-1],{color:'#c85229',radius:7,fillOpacity:1}).addTo(map).bindTooltip('Entrega');");
        currentPolyline=polyline;
    }
    void updateDriver(JSONObject value) {
        fix=value;
        if (!ready || disposed) return;
        String point="null";
        try {
            if(value!=null && ClientRules.validPoint(value.getDouble("latitude"),value.getDouble("longitude")))
                point=new JSONObject().put("lat",value.getDouble("latitude")).put("lng",value.getDouble("longitude")).put("fresh",ClientRules.ageSeconds(value)>=0 && ClientRules.ageSeconds(value)<=60).toString();
        } catch(Exception ignored){ /* Omit malformed coordinates. */ }
        evaluateJavascript("if(typeof setDriver==='function')setDriver("+point+")",null);
    }
    void centerDriver() { if(ready&&!disposed)evaluateJavascript("if(driver)map.setView(driver.getLatLng(),15)",null); }
    void dispose() { disposed=true;stopLoading();destroy(); }
}
