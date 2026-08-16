package com.czw.pcoverview.spw;

import java.io.File;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

public final class BridgeLauncher {
    private final int apiPort;
    private Process process;

    public BridgeLauncher(int apiPort) {
        this.apiPort = apiPort;
    }

    public synchronized void start() {
        if (process != null && process.isAlive()) {
            return;
        }
        if ("false".equalsIgnoreCase(System.getenv("PC_OVERVIEW_AUTOSTART_BRIDGE"))) {
            System.out.println("[pc-overview] PC_OVERVIEW_AUTOSTART_BRIDGE=false, bridge autostart skipped");
            return;
        }
        String dir = resolveBridgeDir();
        if (dir == null) {
            System.out.println("[pc-overview] PC_OVERVIEW_BRIDGE_DIR not found, bridge autostart skipped");
            return;
        }
        if (isLocalPortOpen(8088)) {
            System.out.println("[pc-overview] bridge already listening on 8088, autostart skipped");
            return;
        }
        Path script = Paths.get(dir, "pc_bridge.ps1");
        if (!Files.isRegularFile(script)) {
            System.out.println("[pc-overview] pc_bridge.ps1 missing in " + dir);
            return;
        }

        String logPath = System.getProperty("java.io.tmpdir") + File.separator + "spw-pc-overview-bridge.log";
        ProcessBuilder builder = new ProcessBuilder(
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-WindowStyle", "Hidden",
            "-File", script.toString(),
            "-SaltPluginUrl", "http://127.0.0.1:" + apiPort);
        builder.redirectErrorStream(true);
        builder.redirectOutput(new File(logPath));
        try {
            process = builder.start();
            System.out.println("[pc-overview] bridge autostart launched from " + dir);
        } catch (IOException ex) {
            System.out.println("[pc-overview] bridge autostart failed: " + ex.getMessage());
        }
    }

    public synchronized void stop() {
        if (process != null) {
            process.destroy();
            process = null;
        }
    }

    private static String resolveBridgeDir() {
        String env = System.getenv("PC_OVERVIEW_BRIDGE_DIR");
        if (env != null && !env.trim().isEmpty() && Files.isDirectory(Paths.get(env.trim()))) {
            return env.trim();
        }
        String home = System.getProperty("user.home");
        String[] candidates = {
            home + "/Documents/ChatGPT/holocubic/pc_overview/service",
            "D:/czw/Documents/ChatGPT/holocubic/pc_overview/service",
            "C:/Users/" + System.getProperty("user.name") + "/Documents/ChatGPT/holocubic/pc_overview/service"
        };
        for (String candidate : candidates) {
            if (Files.isDirectory(Paths.get(candidate))) {
                return candidate;
            }
        }
        return null;
    }

    private static boolean isLocalPortOpen(int port) {
        try (Socket socket = new Socket()) {
            socket.connect(new InetSocketAddress("127.0.0.1", port), 500);
            return true;
        } catch (IOException ex) {
            return false;
        }
    }
}
