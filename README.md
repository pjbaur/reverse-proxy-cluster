# reverse-proxy-cluster

A Docker Compose demo of an Apache HTTP Server 2.4 reverse proxy fronting four
interchangeable backends. The proxy is always running and is the only service
with published ports — `8080` (plain HTTP) and `8443` (TLS with a self-signed
dev certificate). Each backend sits behind a Compose profile, so you start
exactly the backends you want and reach all of them through the same proxy by
URL prefix (`/java/`, `/nginx/`, `/node/`, `/python/`). A fifth profile,
`balanced`, puts three replicas of the node backend behind Apache's own load
balancer at `/balanced/` — see [Load-balancing demo](#load-balancing-demo).

## Architecture

```
client ──▶ :8080 (http) ──┐
                          ├──▶ reverse-proxy (httpd:2.4.68-alpine, always on)
client ──▶ :8443 (https) ─┘   │  TLS terminated here, self-signed dev cert
                              │
                              │  proxy-net (internal Docker bridge network)
                              ├─▶ /java/   ──▶ java-backend   :8080  (profile java)
                              ├─▶ /nginx/  ──▶ nginx-backend  :80    (profile nginx)
                              ├─▶ /node/   ──▶ node-backend   :8080  (profile node)
                              ├─▶ /python/ ──▶ python-backend :8080  (profile python)
                              └─▶ /balanced/ ─▶ balancer://demo  (profile balanced)
                                                byrequests round-robin:
                                                ├─▶ node-backend-1 :8080
                                                ├─▶ node-backend-2 :8080
                                                └─▶ node-backend-3 :8080
```

| Service         | Image                                     | Profile  | Published ports | Route       |
| --------------- | ----------------------------------------- | -------- | --------------- | ----------- |
| reverse-proxy   | `httpd:2.4.68-alpine`                     | — (on)   | `8080:80`, `8443:443` | `/` and `/server-status` |
| java-backend    | `eclipse-temurin:21-jre-alpine` (multi-stage build) | `java`   | none            | `/java/`    |
| nginx-backend   | `nginx:1.30-alpine`                       | `nginx`  | none            | `/nginx/`   |
| node-backend    | `node:22-alpine`                          | `node`   | none            | `/node/`    |
| python-backend  | `python:3.12-alpine`                      | `python` | none            | `/python/`  |
| node-backend-1 … 3 | `node:22-alpine` (same build as `node-backend`) | `balanced` | none      | `/balanced/` (via `balancer://demo`) |

All services attach to the `proxy-net` bridge network; the proxy reaches each
backend by its Compose service name (`http://java-backend:8080` and so on).
Backends publish no ports — the host can only reach them through the proxy.

## Quickstart

Requires Docker (Compose v2), OpenSSL >= 1.1.1, and curl.

```sh
# 1. Generate the self-signed dev certificate (gitignored; the build needs it)
scripts/gen-dev-certs.sh

# 2. Start the proxy plus one backend
docker compose --profile java up -d --build

# 3. Exercise it
curl http://localhost:8080/                    # landing page, served by the proxy
curl http://localhost:8080/java/messages       # proxied to the Spring Boot backend
curl -k https://localhost:8443/java/messages   # same route over TLS
```

To run every backend, list all five profiles:

```sh
docker compose --profile java --profile nginx --profile node --profile python --profile balanced up -d --build
```

Teardown — pass the same `--profile` flags you used to start:

```sh
docker compose --profile java down
```

## Routes

| Route               | Served by      | Needs profile | Response                                    |
| ------------------- | -------------- | ------------- | ------------------------------------------- |
| `GET /`             | reverse-proxy  | —             | static landing page                         |
| `GET /java/messages`| java-backend   | `java`        | JSON; echoes `X-Forwarded-*` headers        |
| `GET /nginx/`       | nginx-backend  | `nginx`       | static HTML page                            |
| `GET /nginx/messages` | nginx-backend | `nginx`      | static JSON file                            |
| `GET /node/messages`| node-backend   | `node`        | JSON; echoes `X-Forwarded-*` headers        |
| `GET /python/messages` | python-backend | `python`   | JSON; echoes `X-Forwarded-*` headers        |
| `GET /balanced/messages` | `balancer://demo` | `balanced` | JSON; `host` names the replica that answered |
| `GET /balancer-manager` | reverse-proxy | —             | `mod_proxy_balancer` dashboard              |
| `GET /server-status` | reverse-proxy | —             | Apache `mod_status` page                    |
| any other path      | reverse-proxy  | —             | 404                                         |

`/server-status` accepts only loopback and RFC 1918 source addresses
(`Require ip` in `reverse-proxy/apacheconf/sites/00-server-status.conf`).
`/balancer-manager` carries the same restriction (its `Require ip` lives in
`24-balanced.conf`). Traffic to the published ports arrives from the Docker
bridge gateway, so `curl` from the host and from CI works.

### X-Forwarded headers

`mod_proxy_http` adds `X-Forwarded-For`, `X-Forwarded-Host` and
`X-Forwarded-Server` automatically. `10-proxy.conf` derives the other two per
request — `X-Forwarded-Proto` from `%{REQUEST_SCHEME}` and `X-Forwarded-Port`
from `%{SERVER_PORT}`. Every backend except nginx echoes the three back in its
JSON (`x_forwarded_proto`, `x_forwarded_port`, `x_forwarded_for`), which makes
the proxy's header handling visible: the same endpoint reports
`"x_forwarded_proto":"http"` on port 8080 and `"https"` on port 8443. nginx
serves a static file and cannot echo request headers.

## Load-balancing demo

The `balanced` profile adds a load-balancing tier: three replicas of the node
backend (`node-backend-1` … `node-backend-3`) behind Apache's own
`mod_proxy_balancer`, defined in
`reverse-proxy/apacheconf/sites/24-balanced.conf`:

```sh
# 1. Start the proxy plus the three replicas
docker compose --profile balanced up -d --build

# 2. Ask repeatedly — the "host" field names the replica that answered
for i in 1 2 3 4 5 6; do
  curl -s http://localhost:8080/balanced/messages | grep -o '"host":"[^"]*"'
done
# "host":"node-backend-1" / "node-backend-2" / "node-backend-3" — one
# replica per request (byrequests round-robin)

# 3. Same route over TLS — the *:443 vhost inherits the balancer
curl -k https://localhost:8443/balanced/messages

# 4. Stop it
docker compose --profile balanced down
```

`host` is the serving container's hostname — `node-backend-1`, `-2` or `-3`.
Each replica service sets `hostname:` in `docker-compose.yml` so the JSON
names the member directly; without it, Docker's generated container ID (an
opaque hex string) would appear instead.

The live dashboard at `http://localhost:8080/balancer-manager` lists every
member with its request count (`Elected`), lbfactor and status, and manages
the balancer at runtime: open a member, switch **Draining Mode** to On and
Submit — the balancer stops giving it new requests (in-flight ones finish),
so further `curl`s land on the other two members until you switch it back to
Off. Runtime changes live in shared memory and reset when the proxy restarts.
The page is guarded twice: the same loopback + RFC 1918 source restriction as
`/server-status`, and an XSRF check that silently drops the query parameters
unless the `Referer` names the same host — browsers send that automatically,
a scripted `curl` must add `-H "Referer: http://localhost:8080/…"`.

## Tests

`scripts/smoke.sh` is the test suite. It builds the stack, starts the
requested profiles, waits until every container reports healthy, exercises
each route, then tears the stack down again. All checks run even if an earlier
one failed, and any failure exits non-zero:

```sh
scripts/smoke.sh               # all five profiles — 22 checks
scripts/smoke.sh java node     # any subset
```

It generates the dev certificate itself if `reverse-proxy/certs/server.crt`
is missing, so it is also the one-command verification of a fresh clone.

CI (`.github/workflows/ci.yml`) runs a single job on every push to `master`
and on pull requests: set up buildx, generate the certificate, build five
distinct images — the `balanced` replicas are three services sharing the
single node image — with GitHub Actions layer caching (merged from
`.github/compose.cache.yml`), then run `scripts/smoke.sh`.

The Java backend additionally has `@WebMvcTest` unit tests
(`backends/java/src/test/`). Its image build runs `mvn package` without
`-DskipTests`, so building `java-backend` is itself the test run.

## Configuration model

- `reverse-proxy/httpd.conf` — trimmed base config, Apache 2.4-only syntax,
  17 modules. Serves the landing page, logs to stdout/stderr, and pulls in
  everything else via `IncludeOptional conf/sites/*.conf`.
- `reverse-proxy/apacheconf/sites/` — per-topic config, included in numeric
  (alphabetical) order:
  - `00-server-status.conf` — `mod_status`, loopback + RFC 1918 only.
  - `10-proxy.conf` — shared proxy behaviour: `ProxyRequests Off` (explicit;
    this must never become a forward proxy) and the `X-Forwarded-Proto`/`Port`
    request headers.
  - `20-java.conf` … `23-python.conf` — one `ProxyPass`/`ProxyPassReverse`
    pair per backend, each with `retry=0` so a failed connect is retried on
    the next request instead of poisoning the worker for 60 s.
  - `24-balanced.conf` — the load balancer: `<Proxy "balancer://demo">` with
    three `BalancerMember` lines (`lbmethod=byrequests` round-robin), the
    `/balanced/` `ProxyPass`/`ProxyPassReverse` pair, and the
    `/balancer-manager` dashboard. `retry=0` lives on the `BalancerMember`
    lines, not on the balancer `ProxyPass` — with a `balancer://` target,
    key=value parameters are balancer parameters and httpd rejects worker
    parameters there.
  - `90-ssl.conf` — the only `<VirtualHost>` (`*:443`). Everything else is
    server-level config that port 80 serves directly and the vhost inherits,
    so both listeners behave identically. The `SSLSessionCache` directives
    sit at the top of the file at server level, because Apache rejects them
    inside a `VirtualHost`.
- Config, landing page and certificate are `COPY`d into the image at build
  time — nothing is bind-mounted and there is no live reload. After editing
  anything under `reverse-proxy/`, run `docker compose build reverse-proxy`
  and recreate the container.
- TLS uses a self-signed dev certificate from `scripts/gen-dev-certs.sh`
  (OpenSSL >= 1.1.1, `CN=localhost` with SAN `localhost`/`127.0.0.1`, 10-year
  validity) written to the gitignored `reverse-proxy/certs/`. HTTP to HTTPS
  redirect is deliberately not enabled — plain HTTP on 8080 is part of the
  smoke tests and of the proxy healthcheck. A redirect recipe lives in a
  comment at the bottom of `90-ssl.conf`.
- Image pinning: the proxy is patch-pinned (`httpd:2.4.68-alpine`) because it
  is the demo's subject; the backends are major-pinned
  (`nginx:1.30-alpine`, `node:22-alpine`, `python:3.12-alpine`, Temurin 21).
- Healthchecks are defined once in `docker-compose.yml` using the `wget`
  built into every Alpine image (busybox). `nginx-backend`, `python-backend`,
  and the three balanced replicas (`node-backend-1/2/3`) probe
  `http://127.0.0.1/...` because their listeners are IPv4-only while busybox
  `wget` resolves `localhost` to `::1` first; `reverse-proxy` and
  `java-backend` use `localhost`. Every service sets
  `restart: unless-stopped`.

## Troubleshooting

- **Build fails with `COPY failed ... certs/server.crt: not found`** — the
  dev certificate is missing. Run `scripts/gen-dev-certs.sh`, then rebuild.
- **`address already in use` on port 8080 or 8443** — change the published
  ports in `docker-compose.yml` and the matching `BASE_HTTP`/`BASE_HTTPS` in
  `scripts/smoke.sh`, then restart.
- **502 on a backend route** — that backend's profile is not running. Start
  it with `docker compose --profile <name> up -d`. Because of `retry=0` the
  route recovers on the next request; the other routes are unaffected.
- **`curl` rejects the certificate on 8443** — it is self-signed. Use
  `curl -k`, or import `reverse-proxy/certs/server.crt` into your trust
  store.
- **403 on `/server-status`** — the source address is outside loopback and
  RFC 1918. That is the intended policy.

## Background

`docs/REVIEW.md` is the frozen review that motivated the modernization of the
proxy image (pinning, trimming, 2.4-only config). It is a historical record —
do not update it to match later changes.
