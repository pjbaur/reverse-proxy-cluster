package com.example.messages;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.LinkedHashMap;
import java.util.Map;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;

/**
 * The single endpoint mirrored by every backend in this demo:
 * GET /messages -> JSON identifying who answered and which X-Forwarded-*
 * headers arrived (they prove the reverse proxy is setting them).
 */
@RestController
public class MessageController {

    @GetMapping("/messages")
    public Map<String, Object> messages(
            @RequestHeader(value = "X-Forwarded-Proto", required = false) String forwardedProto,
            @RequestHeader(value = "X-Forwarded-Port", required = false) String forwardedPort,
            @RequestHeader(value = "X-Forwarded-For", required = false) String forwardedFor) {

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("backend", "java");
        body.put("message", "Hello from Spring Boot");
        body.put("host", hostname());
        body.put("x_forwarded_proto", forwardedProto);
        body.put("x_forwarded_port", forwardedPort);
        body.put("x_forwarded_for", forwardedFor);
        return body;
    }

    private static String hostname() {
        try {
            return InetAddress.getLocalHost().getHostName();
        } catch (UnknownHostException e) {
            return "unknown";
        }
    }
}
