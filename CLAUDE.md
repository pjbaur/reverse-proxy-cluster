# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

Docker Compose demo: an Apache HTTP Server 2.4 reverse proxy in front of four
optional backends. The proxy (`reverse-proxy`, `httpd:2.4.68-alpine`) is always
on and publishes the only host ports — `8080:80` and `8443:443` (self-signed
TLS). Every backend is gated behind a Compose profile, attaches to the
`proxy-net` bridge network, publishes no ports, and is reachable only through
the proxy by URL prefix:

| Prefix    | Backend         | Profile  | Stack                        |
| --------- | --------------- | -------- | ---------------------------- |
| `/java/`  | java-backend    | `java`   | Spring Boot 3.5 / Java 21    |
| `/nginx/` | nginx-backend   | `nginx`  | static nginx                 |
| `/node/`  | node-backend    | `node`   | zero-dependency `node:http`  |
| `/python/`| python-backend  | `python` | stdlib `http.server`         |

The test suite is `scripts/smoke.sh`; the Java unit tests run inside the
`java-backend` image build. See README.md for the full architecture.

## Commands

```sh
# Generate the dev TLS certificate (required before the proxy image builds)
scripts/gen-dev-certs.sh

# Start the proxy plus one backend, or all four
docker compose --profile java up -d --build
docker compose --profile java --profile nginx --profile node --profile python up -d --build

# Test suite — all profiles (17 checks) or any subset
scripts/smoke.sh
scripts/smoke.sh java node

# Logs
docker compose logs -f reverse-proxy
docker compose logs -f java-backend

# Tear down — pass the same profiles you started
docker compose --profile java down
```

## Structure

- `docker-compose.yml` — all five services, the `proxy-net` network, published
  ports, and the single source of truth for healthchecks (busybox `wget`).
- `reverse-proxy/Dockerfile` — patch-pinned base image; bakes in `httpd.conf`,
  `apacheconf/sites/`, the landing page and the dev certificate.
- `reverse-proxy/httpd.conf` — trimmed, 2.4-only base config (14 modules);
  `IncludeOptional conf/sites/*.conf`.
- `reverse-proxy/apacheconf/sites/` — numbered per-topic config:
  `00-server-status.conf` (loopback + RFC 1918), `10-proxy.conf`
  (`ProxyRequests Off`, `X-Forwarded-Proto`/`Port`), `20`–`23` one file per
  backend route, `90-ssl.conf` (the only `<VirtualHost *:443>`; inherits all
  server-level routing).
- `backends/<name>/` — one self-contained directory per backend (Dockerfile +
  app). Contract: listen on a port; `GET /messages` returns JSON with
  `backend`, `message`, `host` and the echoed `X-Forwarded-Proto`/`Port`/`For`
  headers (nginx, being static, serves that JSON as a file instead).
- `scripts/gen-dev-certs.sh` — writes the self-signed certificate into the
  gitignored `reverse-proxy/certs/`.
- `scripts/smoke.sh` — build, start, wait for health, check every route, tear
  down; exits non-zero on any failure.
- `.github/workflows/ci.yml` + `.github/compose.cache.yml` — CI builds all
  profiles with GitHub Actions layer caches, then runs the smoke suite.
- `docs/REVIEW.md` — frozen historical review; do not update it.

## Conventions

- **Rebuild, don't reload.** Proxy config, static content and certificates are
  baked into the image — no bind mounts, no live reload. After editing
  anything under `reverse-proxy/` (or a backend), rebuild and recreate:
  `docker compose build reverse-proxy && docker compose --profile <name> up -d`.
- **Adding a backend:**
  1. Create `backends/<name>/` — self-contained Dockerfile plus app, listening
     on a known port.
  2. Add a Compose service: build context, `profiles: ["<name>"]`, on
     `proxy-net`, no published ports, busybox-`wget` healthcheck,
     `restart: unless-stopped`:

     ```yaml
     <name>-backend:
       build: ./backends/<name>
       profiles: ["<name>"]
       restart: unless-stopped
       networks:
         - proxy-net
       healthcheck:
         test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:<port>/messages"]
         interval: 10s
         timeout: 3s
         retries: 3
         start_period: 5s
     ```

     Probe `127.0.0.1` when the server listens IPv4-only (busybox `wget`
     resolves `localhost` to `::1` first); give slow starters a longer
     `start_period` (java uses 20s).
  3. Add `reverse-proxy/apacheconf/sites/2x-<name>.conf` (next free number)
     with server-level directives only — no vhost edits:

     ```apache
     ProxyPass        /<name>/ http://<name>-backend:<port>/ retry=0
     ProxyPassReverse /<name>/ http://<name>-backend:<port>/
     ```

  4. Rebuild the proxy image, then run `scripts/smoke.sh <name>`.
- **Apache 2.4 syntax only** in all proxy configuration.
- **Pinning:** the proxy is patch-pinned (it is the demo's subject); backends
  are major-pinned.
- **Commits:** conventional commit subjects (`feat:`, `fix:`, `docs:`, ...).
- Before committing, run `scripts/smoke.sh` with the profiles you touched.
