package com.czw.pcoverview.spw;

import java.net.HttpURLConnection;
import java.net.URL;

public final class BridgeNotifier {
    private static final String DEFAULT_BRIDGE_URL = "http://127.0.0.1:8088";

    private BridgeNotifier() {
    }

    public static void mediaChanged() {
        request("/salt-media-changed");
    }

    private static void request(String path) {
        Thread thread = new Thread(() -> {
            try {
                String base = System.getenv("PC_OVERVIEW_BRIDGE_URL");
                if (base == null || base.trim().isEmpty()) {
                    base = DEFAULT_BRIDGE_URL;
                }
                URL url = new URL(base + path);
                HttpURLConnection connection = (HttpURLConnection) url.openConnection();
                connection.setConnectTimeout(1000);
                connection.setReadTimeout(1000);
                try {
                    connection.getResponseCode();
                } finally {
                    connection.disconnect();
                }
            } catch (Exception ignored) {
            }
        }, "spw-pc-overview-bridge-notify");
        thread.setDaemon(true);
        thread.start();
    }
}
