package com.czw.pcoverview.spw;

import com.xuncorp.spw.workshop.api.PlaybackExtensionPoint;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;

public final class HttpApiServer {
    private final int port;
    private volatile boolean running;
    private ServerSocket serverSocket;
    private Thread acceptThread;

    public HttpApiServer(int port) {
        this.port = port;
    }

    public void start() throws IOException {
        running = true;
        serverSocket = new ServerSocket(port, 16, InetAddress.getLoopbackAddress());
        acceptThread = new Thread(this::acceptLoop, "spw-pc-overview-http");
        acceptThread.setDaemon(true);
        acceptThread.start();
    }

    public void stop() {
        running = false;
        if (serverSocket != null) {
            try {
                serverSocket.close();
            } catch (IOException ignored) {
            }
            serverSocket = null;
        }
    }

    private void acceptLoop() {
        while (running) {
            try {
                Socket socket = serverSocket.accept();
                Thread worker = new Thread(() -> handle(socket), "spw-pc-overview-http-worker");
                worker.setDaemon(true);
                worker.start();
            } catch (IOException ignored) {
                if (running) {
                    try {
                        Thread.sleep(50L);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                        return;
                    }
                }
            }
        }
    }

    private void handle(Socket socket) {
        try (Socket closeable = socket) {
            socket.setSoTimeout(2000);
            BufferedReader reader = new BufferedReader(
                new InputStreamReader(socket.getInputStream(), StandardCharsets.ISO_8859_1));
            String requestLine = reader.readLine();
            if (requestLine == null || requestLine.isEmpty()) {
                return;
            }
            String[] parts = requestLine.split(" ");
            String method = parts.length > 0 ? parts[0] : "";
            String path = parts.length > 1 ? parts[1] : "/";
            while (true) {
                String line = reader.readLine();
                if (line == null || line.isEmpty()) {
                    break;
                }
            }

            String body;
            String contentType;
            if ("GET".equals(method) && "/api/media".equals(path)) {
                contentType = "application/json; charset=utf-8";
                body = mediaJson();
            } else if ("GET".equals(method) && "/health".equals(path)) {
                contentType = "application/json; charset=utf-8";
                body = "{\"ok\":true}";
            } else {
                contentType = "text/plain; charset=utf-8";
                body = "not found";
                writeResponse(socket.getOutputStream(), "404 Not Found", contentType, body);
                return;
            }
            writeResponse(socket.getOutputStream(), "200 OK", contentType, body);
        } catch (IOException ignored) {
        }
    }

    private static String mediaJson() {
        PlaybackExtensionPoint.MediaItem media = PlaybackState.media;
        StringBuilder json = new StringBuilder(320);
        json.append("{\"ok\":true,");
        json.append("\"title\":").append(jsonString(media == null ? "" : media.getTitle())).append(",");
        json.append("\"artist\":").append(jsonString(media == null ? "" : media.getArtist())).append(",");
        json.append("\"album\":").append(jsonString(media == null ? "" : media.getAlbum())).append(",");
        json.append("\"albumArtist\":").append(jsonString(media == null ? "" : media.getAlbumArtist())).append(",");
        json.append("\"path\":").append(jsonString(media == null ? "" : media.getPath())).append(",");
        json.append("\"playing\":").append(PlaybackState.playing ? "true" : "false").append(",");
        json.append("\"state\":").append(jsonString(PlaybackState.state == null ? "Idle" : PlaybackState.state)).append(",");
        json.append("\"position\":").append(PlaybackState.position).append("}");
        return json.toString();
    }

    private static String jsonString(String value) {
        if (value == null) {
            return "\"\"";
        }
        StringBuilder out = new StringBuilder(value.length() + 8);
        out.append('"');
        for (int i = 0; i < value.length(); i++) {
            char ch = value.charAt(i);
            switch (ch) {
                case '\\':
                    out.append("\\\\");
                    break;
                case '"':
                    out.append("\\\"");
                    break;
                case '\r':
                    out.append("\\r");
                    break;
                case '\n':
                    out.append("\\n");
                    break;
                case '\t':
                    out.append("\\t");
                    break;
                default:
                    if (ch < 0x20) {
                        out.append(String.format("\\u%04x", (int) ch));
                    } else {
                        out.append(ch);
                    }
            }
        }
        out.append('"');
        return out.toString();
    }

    private static void writeResponse(OutputStream out, String status, String contentType, String body)
            throws IOException {
        byte[] bodyBytes = body.getBytes(StandardCharsets.UTF_8);
        StringBuilder header = new StringBuilder();
        header.append("HTTP/1.1 ").append(status).append("\r\n");
        header.append("Content-Type: ").append(contentType).append("\r\n");
        header.append("Content-Length: ").append(bodyBytes.length).append("\r\n");
        header.append("Connection: close\r\n");
        header.append("Access-Control-Allow-Origin: *\r\n\r\n");
        out.write(header.toString().getBytes(StandardCharsets.ISO_8859_1));
        out.write(bodyBytes);
        out.flush();
    }
}
