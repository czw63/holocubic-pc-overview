package com.czw.pcoverview.spw;

import java.io.FileWriter;
import java.io.PrintWriter;
import java.text.SimpleDateFormat;
import java.util.Date;

public final class PluginLog {
    private static final String PATH =
        System.getProperty("java.io.tmpdir") + System.getProperty("file.separator") +
        "spw-pc-overview-plugin.log";

    private PluginLog() {
    }

    public static void log(String message) {
        String line = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS").format(new Date()) +
            " " + message;
        try (PrintWriter writer = new PrintWriter(new FileWriter(PATH, true))) {
            writer.println(line);
        } catch (Exception ignored) {
        }
        System.out.println("[pc-overview] " + line);
    }
}
