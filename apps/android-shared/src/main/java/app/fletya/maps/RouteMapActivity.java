package app.fletya.maps;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.os.Bundle;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import com.google.android.gms.maps.CameraUpdateFactory;
import com.google.android.gms.maps.MapView;
import com.google.android.gms.maps.model.LatLng;
import com.google.android.gms.maps.model.LatLngBounds;
import com.google.android.gms.maps.model.MarkerOptions;
import com.google.android.gms.maps.model.PolylineOptions;
import org.json.JSONArray;
import java.util.ArrayList;
import java.util.List;

public final class RouteMapActivity extends Activity {
    private MapView map;

    public static void show(Activity activity, JSONArray points) {
        String coordinates = points.toString();
        if (coordinates.length() > 200_000) {
            android.widget.Toast.makeText(activity, "El recorrido es demasiado largo para abrirlo.", android.widget.Toast.LENGTH_SHORT).show();
            return;
        }
        activity.startActivity(new Intent(activity, RouteMapActivity.class).putExtra("points", coordinates));
    }

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        var layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        var back = new Button(this);
        back.setText("Volver a FLETYA");
        back.setAllCaps(false);
        back.setOnClickListener(view -> finish());
        layout.addView(back);
        layout.setOnApplyWindowInsetsListener((view, insets) -> {
            view.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(),
                insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            return insets;
        });
        setContentView(layout);
        layout.requestApplyInsets();

        List<LatLng> points = new ArrayList<>();
        try {
            var values = new JSONArray(getIntent().getStringExtra("points"));
            if (values.length() < 2) throw new IllegalArgumentException();
            for (int i = 0; i < values.length(); i++) {
                var point = values.getJSONArray(i);
                points.add(new LatLng(point.getDouble(0), point.getDouble(1)));
            }
        } catch (Exception error) {
            var status = new TextView(this);
            status.setText("No se pudo abrir la ruta.");
            layout.addView(status);
            return;
        }

        map = new MapView(this);
        layout.addView(map, new LinearLayout.LayoutParams(-1, 0, 1));
        map.onCreate(state == null ? null : state.getBundle("map"));
        map.getMapAsync(googleMap -> {
            if (isDestroyed() || isFinishing()) return;
            googleMap.getUiSettings().setMapToolbarEnabled(false);
            googleMap.getUiSettings().setZoomControlsEnabled(true);
            googleMap.addPolyline(new PolylineOptions().addAll(points).color(Color.rgb(8, 127, 136)).width(13));
            googleMap.addMarker(new MarkerOptions().position(points.get(0)).title("Recogida"));
            googleMap.addMarker(new MarkerOptions().position(points.get(points.size() - 1)).title("Entrega"));
            var bounds = new LatLngBounds.Builder();
            for (LatLng point : points) bounds.include(point);
            if (state == null) {
                googleMap.setOnMapLoadedCallback(() -> {
                    if (!isDestroyed() && map.getWidth() > 96 && map.getHeight() > 96) {
                        googleMap.moveCamera(CameraUpdateFactory.newLatLngBounds(bounds.build(), 48));
                    }
                });
            }
        });
    }

    @Override protected void onStart() { super.onStart(); if (map != null) map.onStart(); }
    @Override protected void onResume() { super.onResume(); if (map != null) map.onResume(); }
    @Override protected void onPause() { if (map != null) map.onPause(); super.onPause(); }
    @Override protected void onStop() { if (map != null) map.onStop(); super.onStop(); }
    @Override protected void onDestroy() { if (map != null) map.onDestroy(); super.onDestroy(); }
    @Override public void onLowMemory() { super.onLowMemory(); if (map != null) map.onLowMemory(); }
    @Override protected void onSaveInstanceState(Bundle state) {
        super.onSaveInstanceState(state);
        if (map != null) {
            var mapState = new Bundle();
            map.onSaveInstanceState(mapState);
            state.putBundle("map", mapState);
        }
    }
}
