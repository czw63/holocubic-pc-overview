package test;

import com.czw.pcoverview.spw.HttpApiServer;

public final class HttpServerSmoke {
    public static void main(String[] args) throws Exception {
        HttpApiServer server = new HttpApiServer(8091);
        server.start();
        System.out.println("HTTP_SMOKE_STARTED");
        Thread.sleep(4000L);
        server.stop();
    }
}
