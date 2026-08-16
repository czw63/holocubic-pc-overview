package com.czw.pcoverview.spw;

import org.pf4j.Plugin;
import org.pf4j.PluginWrapper;

public final class SpwPcOverviewPlugin extends Plugin {
    private HttpApiServer server;
    private BridgeLauncher bridge;

    public SpwPcOverviewPlugin(PluginWrapper wrapper) {
        super(wrapper);
    }

    @Override
    public void start() {
        super.start();
        PlaybackState.reset();
        int port = resolvePort();
        server = new HttpApiServer(port);
        try {
            server.start();
            System.out.println("[pc-overview] SPW plugin HTTP API started on 127.0.0.1:" + port);
            if (!"false".equalsIgnoreCase(System.getenv("PC_OVERVIEW_AUTOSTART_BRIDGE"))) {
                bridge = new BridgeLauncher(port);
                bridge.start();
            }
        } catch (Exception ex) {
            System.out.println("[pc-overview] SPW plugin HTTP start failed: " + ex.getMessage());
            server = null;
        }
    }

    @Override
    public void stop() {
        if (bridge != null) {
            bridge.stop();
            bridge = null;
        }
        if (server != null) {
            server.stop();
            server = null;
        }
        super.stop();
    }

    private static int resolvePort() {
        String env = System.getenv("SPW_PC_OVERVIEW_PORT");
        if (env != null && !env.trim().isEmpty()) {
            try {
                return Integer.parseInt(env.trim());
            } catch (NumberFormatException ignored) {
            }
        }
        int property = Integer.getInteger("spw.pc.overview.port", 8091);
        return property > 0 ? property : 8091;
    }
}
