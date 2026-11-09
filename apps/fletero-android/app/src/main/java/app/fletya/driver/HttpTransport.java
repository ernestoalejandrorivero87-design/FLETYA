package app.fletya.driver;

import org.json.JSONObject;
import java.net.HttpURLConnection;
import java.net.URI;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

final class HttpTransport implements DriverApi.Transport {
    private String readUtf8(InputStream stream) throws java.io.IOException {
        java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream();
        byte[] buffer = new byte[8192];
        int count;
        while ((count = stream.read(buffer)) != -1) {
            if (bytes.size() + count > 2_000_000) throw new java.io.IOException("Respuesta demasiado grande");
            bytes.write(buffer, 0, count);
        }
        return new String(bytes.toByteArray(), StandardCharsets.UTF_8);
    }
    @Override public DriverApi.Response send(String method, String path, String accessToken, JSONObject body, String prefer) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) URI.create(BuildConfig.SUPABASE_URL + path).toURL().openConnection();
        connection.setInstanceFollowRedirects(false); // Never forward credentials to another host.
        connection.setConnectTimeout(12_000);
        connection.setReadTimeout(15_000);
        connection.setRequestMethod(method);
        connection.setRequestProperty("apikey", BuildConfig.SUPABASE_KEY);
        connection.setRequestProperty("Accept", "application/json");
        if (accessToken != null) connection.setRequestProperty("Authorization", "Bearer " + accessToken);
        if (prefer != null) connection.setRequestProperty("Prefer", prefer);
        try {
            if (body != null) {
                connection.setRequestProperty("Content-Type", "application/json");
                connection.setDoOutput(true);
                try (var out = connection.getOutputStream()) { out.write(body.toString().getBytes(StandardCharsets.UTF_8)); }
            }
            int status = connection.getResponseCode();
            InputStream stream = status >= 400 ? connection.getErrorStream() : connection.getInputStream();
            String value = "";
            if (stream != null) try (stream) { value = readUtf8(stream); }
            return new DriverApi.Response(status, value);
        } finally { connection.disconnect(); }
    }
}
