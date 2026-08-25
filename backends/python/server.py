#!/usr/bin/env python3
"""Zero-dependency Python backend (profile "python"): stdlib http.server only.

separators=(",", ":") keeps the JSON compact so smoke assertions that match
substrings like "backend":"python" behave the same across all backends.
"""

import json
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8080


class MessageHandler(BaseHTTPRequestHandler):
    server_version = "PythonBackend/1.0"

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/messages":
            body = json.dumps(
                {
                    "backend": "python",
                    "message": "Hello from Python",
                    "host": socket.gethostname(),
                    "x_forwarded_proto": self.headers.get("X-Forwarded-Proto"),
                    "x_forwarded_port": self.headers.get("X-Forwarded-Port"),
                    "x_forwarded_for": self.headers.get("X-Forwarded-For"),
                },
                separators=(",", ":"),
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        body = json.dumps({"error": "not found", "path": path},
                          separators=(",", ":")).encode("utf-8")
        self.send_response(404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        # container-native: everything on stdout, unbuffered (python -u)
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), MessageHandler).serve_forever()
