#!/bin/sh
# Generate the self-signed certificate for the proxy's HTTPS listener.
# Requires OpenSSL >= 1.1.1 (uses `req -addext` for the SAN).
# Output is gitignored; the proxy Dockerfile bakes it into the image, so after
# regenerating run: docker compose build reverse-proxy
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERT_DIR="$ROOT/reverse-proxy/certs"

mkdir -p "$CERT_DIR"

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$CERT_DIR/server.key" \
  -out "$CERT_DIR/server.crt" \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

chmod 600 "$CERT_DIR/server.key"

echo "Wrote $CERT_DIR/server.crt"
echo "Wrote $CERT_DIR/server.key"
