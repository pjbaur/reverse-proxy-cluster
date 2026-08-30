# reverse-proxy-cluster

A Docker Compose demo of an Apache HTTP Server 2.4 reverse proxy fronting four
interchangeable backends. The proxy is always running and is the only service
with published ports — `8080` (plain HTTP) and `8443` (TLS with a self-signed
dev certificate). Each backend sits behind a Compose profile, so you start
exactly the backends you want and reach all of them through the same proxy by
URL prefix (`/java/`, `/nginx/`, `/node/`, `/python/`). A fifth profile,
`balanced`, puts three replicas of the node backend behind Apache's own load
balancer at `/balanced/` — see [Load-balancing demo](#load-balancing-demo).
A sixth profile, `failover`, pairs an active primary with a hot standby at
`/failover/` — see [Failover demo](#failover-demo).
A seventh profile, `sticky`, pins each client to one member via a session
cookie or a URL-embedded session id at `/sticky/` — see
[Sticky sessions demo](#sticky-sessions-demo).
An eighth profile, `busy`, routes by in-flight request count
(`lbmethod=bybusyness`) at `/busy/` — see [Busy demo](#busy-demo-bybusyness).
A ninth profile, `stickyfailover`, combines session affinity with a hot
standby at `/stickyfailover/` and `/stickyfailover-strict/` — see
[Sticky failover demo](#sticky-failover-demo).

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
                              ├─▶ /balanced/ ─▶ balancer://demo  (profile balanced)
                              │                 byrequests round-robin:
                              │                 ├─▶ node-backend-1 :8080
                              │                 ├─▶ node-backend-2 :8080
                              │                 └─▶ node-backend-3 :8080
                              ├─▶ /failover/ ─▶ balancer://failover (profile failover)
                              │                 hot standby (status=+H):
                              │                 ├─▶ node-backend-primary :8080  ◀─ serves all
                              │                 └─▶ node-backend-standby :8080  ◀─ on error only
                              ├─▶ /sticky/  ─▶ balancer://sticky  (profile sticky)
                              │                 session affinity (stickysession=SESSIONID):
                              │                 ├─▶ node-backend-sticky-1 :8080  ◀─ cookie suffix .node-backend-sticky-1
                              │                 └─▶ node-backend-sticky-2 :8080  ◀─ cookie suffix .node-backend-sticky-2
                              ├─▶ /busy/    ─▶ balancer://busy     (profile busy)
                              │                 bybusyness (fewest active requests):
                              │                 ├─▶ node-backend-busy-1 :8080  ◀─ skipped while holding a ?delay=ms request
                              │                 └─▶ node-backend-busy-2 :8080
                              ├─▶ /stickyfailover/ ─▶ balancer://stickyfailover (profile stickyfailover)
                              │                 sticky hot standby (a pinned session fails over):
                              │                 ├─▶ node-backend-sf-primary :8080  ◀─ serves all
                              │                 └─▶ node-backend-sf-standby :8080  ◀─ on error only
                              └─▶ /stickyfailover-strict/ ─▶ balancer://stickyfailover-strict
                                                nofailover=On (a pinned session breaks, 503):
                                                └─▶ the same two members as /stickyfailover/
```

| Service         | Image                                     | Profile  | Published ports | Route       |
| --------------- | ----------------------------------------- | -------- | --------------- | ----------- |
| reverse-proxy   | `httpd:2.4.68-alpine`                     | — (on)   | `8080:80`, `8443:443` | `/` and `/server-status` |
| java-backend    | `eclipse-temurin:21-jre-alpine` (multi-stage build) | `java`   | none            | `/java/`    |
| nginx-backend   | `nginx:1.30-alpine`                       | `nginx`  | none            | `/nginx/`   |
| node-backend    | `node:22-alpine`                          | `node`   | none            | `/node/`    |
| python-backend  | `python:3.12-alpine`                      | `python` | none            | `/python/`  |
| node-backend-1 … 3 | `node:22-alpine` (same build as `node-backend`) | `balanced` | none      | `/balanced/` (via `balancer://demo`) |
| node-backend-primary, node-backend-standby | `node:22-alpine` (same build as `node-backend`) | `failover` | none | `/failover/` (via `balancer://failover`) |
| node-backend-sticky-1, node-backend-sticky-2 | `node:22-alpine` (same build as `node-backend`) | `sticky` | none | `/sticky/` (via `balancer://sticky`) |
| node-backend-busy-1, node-backend-busy-2 | `node:22-alpine` (same build as `node-backend`) | `busy` | none | `/busy/` (via `balancer://busy`) |
| node-backend-sf-primary, node-backend-sf-standby | `node:22-alpine` (same build as `node-backend`) | `stickyfailover` | none | `/stickyfailover/` and `/stickyfailover-strict/` (via `balancer://stickyfailover(-strict)`) |

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

To run every backend, list all nine profiles:

```sh
docker compose --profile java --profile nginx --profile node --profile python --profile balanced --profile failover --profile sticky --profile busy --profile stickyfailover up -d --build
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
| `GET /failover/messages` | `balancer://failover` | `failover` | JSON; `host` is `node-backend-primary`, or `-standby` while it is down |
| `GET /sticky/messages` | `balancer://sticky` | `sticky` | JSON; `host` is constant per client cookie, alternating without one; `?SESSIONID=<id>.<route>` or `;SESSIONID=...` in the URL pins without a cookie and overrides the cookie |
| `GET /busy/messages[?delay=ms]` | `balancer://busy` | `busy` | JSON; while a `?delay=` request is in flight, every fast request lands on the *other* member |
| `GET /stickyfailover/messages` | `balancer://stickyfailover` | `stickyfailover` | JSON; a pinned session moves to `-standby` while the primary is down and **stays there** after recovery |
| `GET /stickyfailover-strict/messages` | `balancer://stickyfailover-strict` | `stickyfailover` | JSON while healthy; **503** for a pinned client while its member is down |
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

## Failover demo

The `failover` profile adds a hot-standby pair: the node backend twice
(`node-backend-primary` + `node-backend-standby`) behind
`balancer://failover` in `reverse-proxy/apacheconf/sites/25-failover.conf`.
The primary serves everything; the standby — marked `status=+H` — only
answers while the primary is in error state. The primary carries
`retry=5`, not the project's usual `retry=0`: hot standby engages through
the worker error state, which `retry=0` would wipe instantly (every
request would re-elect the dead primary and 503). The bounded 5 s window
activates the standby the moment the primary fails and re-elects the
primary within 5 s of it returning:

```sh
docker compose --profile failover up -d --build

# every request answers from the primary
curl -s http://localhost:8080/failover/messages | grep -o '"host":"[^"]*"'

# kill the primary — from the second request on, the standby answers
docker compose --profile failover stop node-backend-primary
curl -s http://localhost:8080/failover/messages | grep -o '"host":"[^"]*"'

# restart the primary — traffic returns on the next request
docker compose --profile failover up -d --wait node-backend-primary
curl -s http://localhost:8080/failover/messages | grep -o '"host":"[^"]*"'

curl -k https://localhost:8443/failover/messages   # same route over TLS
docker compose --profile failover down
```

The first request after the stop is the transition itself and is
nondeterministic: Compose removes the stopped container's DNS entry, so
the balancer either answers 500 (DNS lookup failure, no in-request
deferral) or blocks on the dead address for up to Apache's 60 s `Timeout`
before retrying on the standby. Either outcome puts the primary worker
into error state, and every request from the second onward is served by
the standby; the smoke suite warms the transition request through before
asserting the steady state.

`/balancer-manager` lists both balancers; the standby's status column reads
`Stby` (the `status=+H` flag, shown only on the standby) and its `Elected`
count stays `0` until the failover.

## Sticky sessions demo

The `sticky` profile adds session affinity: the node backend twice
(`node-backend-sticky-1` + `node-backend-sticky-2`) behind
`balancer://sticky` in `reverse-proxy/apacheconf/sites/26-sticky.conf`.
Each service exports `ROUTE=<its own name>`, and the node app bakes that
route into its session cookie — `Set-Cookie: SESSIONID=<uuid>.<ROUTE>` —
jvmRoute-style, exactly how a Tomcat worker embeds its route in
`JSESSIONID`. The balancer (`ProxySet stickysession=SESSIONID`) reads the
cookie, splits the value on the first `.`, and sends the client to the
member whose `route=` matches the suffix. Clients without the cookie fall
through to plain round-robin:

```sh
docker compose --profile sticky up -d --build

# cookie-less: the members alternate (plain byrequests round-robin)
for i in 1 2 3 4; do
  curl -s http://localhost:8080/sticky/messages | grep -o '"host":"[^"]*"'
done

# cookie-jar client: pinned to one member on every request
for i in 1 2 3 4; do
  curl -s -c jar.txt -b jar.txt http://localhost:8080/sticky/messages | grep -o '"host":"[^"]*"'
done
grep -o 'node-backend-sticky-[12]' jar.txt | sort -u   # the one member this jar is pinned to

curl -v http://localhost:8080/sticky/messages 2>&1 | grep -i set-cookie
# Set-Cookie: SESSIONID=<uuid>.node-backend-sticky-1   <- the route suffix

curl -k https://localhost:8443/sticky/messages   # same route over TLS
docker compose --profile sticky down
```

A second jar (`-c jar2.txt -b jar2.txt`) pins independently — it may land
on either member, but it stays there: affinity is per client, not global.

The session id can also travel in the URL itself, no cookie required —
the same `stickysession=SESSIONID` reads it. Two forms: a query
parameter (`?SESSIONID=<id>.<route>`, always enabled) and the
servlet-style path parameter (`;SESSIONID=<id>.<route>`, enabled by
`scolonpathdelim=On` in `26-sticky.conf`; the node app strips the
`;`-segment the way a servlet container would). A URL parameter takes
precedence over a cookie, and an unknown route id is simply ignored
(round-robin):

```sh
# pin by query parameter — lands on sticky-2
curl -s "http://localhost:8080/sticky/messages?SESSIONID=x.node-backend-sticky-2" | grep -o '"host":"[^"]*"'

# pin by servlet-style path parameter — lands on sticky-1
curl -s "http://localhost:8080/sticky/messages;SESSIONID=x.node-backend-sticky-1" | grep -o '"host":"[^"]*"'

# a URL parameter beats the cookie: jar pinned to sticky-1, URL says sticky-2
curl -s -c jar.txt -b jar.txt "http://localhost:8080/sticky/messages;SESSIONID=x.node-backend-sticky-1" >/dev/null
curl -s -c jar.txt -b jar.txt "http://localhost:8080/sticky/messages?SESSIONID=x.node-backend-sticky-2" | grep -o '"host":"[^"]*"'

# unknown route id: no error, plain round-robin
curl -s "http://localhost:8080/sticky/messages?SESSIONID=x.no-such-route" | grep -o '"host":"[^"]*"'
```

httpd 2.4 has no `stickyforce` knob (the name floats around old mailing
lists); the behavior people usually mean by it — a pinned session
breaking with 503 instead of failing over — is `nofailover=On`, which
the [stickyfailover demo](#sticky-failover-demo) shows. The proxy never
rewrites session ids into response URLs: embedding them in the links it
serves is the backend's job (servlet containers do it when they render
pages).

`/balancer-manager` lists the `sticky` balancer with each member's route
in its URL column.

If the cookie name, the `.` suffix, or the route/`ROUTE`/service-name
triple ever drifts, stickiness degrades silently to round-robin — no
error, just rotation. The smoke suite's pinning checks are the guard.

## Busy demo (bybusyness)

The `busy` profile adds a second load-balancing method: the node backend
twice (`node-backend-busy-1` + `node-backend-busy-2`) behind
`balancer://busy` in `reverse-proxy/apacheconf/sites/27-busy.conf`, this
time with `ProxySet lbmethod=bybusyness`. Where `byrequests` (the
`balanced` demo) alternates by request count, `bybusyness` elects the
member with the fewest *active* requests — so a member holding a long
request is skipped until it finishes. The node backend's `?delay=<ms>`
parameter (clamped 0–10000) is how a request is made long:

```sh
docker compose --profile busy up -d --build

# terminal 1 — hold one member busy for 5 s (note which host answers)
curl -s "http://localhost:8080/busy/messages?delay=5000" | grep -o '"host":"[^"]*"'

# terminal 2, while terminal 1 hangs — every fast request takes the OTHER member
curl -s http://localhost:8080/busy/messages | grep -o '"host":"[^"]*"'

curl -k https://localhost:8443/busy/messages   # same route over TLS
docker compose --profile busy down
```

Node answers concurrent requests fine — the member is not saturated; what
you are watching is the balancer's routing decision, which is exactly what
`bybusyness` exposes and `byrequests` ignores. `/balancer-manager` lists
the `busy` balancer; its `Elected` counts diverge while a slow request
runs.

## Sticky failover demo

The `stickyfailover` profile answers what the `sticky` and `failover` demos
exercise separately: what a pinned session does when its member dies. The
node backend twice (`node-backend-sf-primary` + `node-backend-sf-standby`)
sits behind **two** balancers that differ only in one `ProxySet` flag, in
`reverse-proxy/apacheconf/sites/28-stickyfailover.conf`:

- `balancer://stickyfailover` (default `nofailover=Off`) — a pinned session
  **moves**: the primary's failure puts its worker in error state, the
  request falls back to the `status=+H` standby, and the standby's response
  rewrites the cookie to the standby's route. When the primary returns, the
  session **stays on the standby** — a healthy hot standby is a valid
  sticky target, so recovery re-homes only new, cookie-less clients.
- `balancer://stickyfailover-strict` (`nofailover=On`) — a pinned session
  **breaks**: requests whose cookie names the dead primary get `503`
  instead of silently moving (the behavior to want when backends do not
  replicate sessions). Cookie-less clients still get the standby. The
  session's cookie kept naming the primary the whole time, so it resumes
  **on the primary** the moment it recovers.

```sh
docker compose --profile stickyfailover up -d --build

# pin a jar to the primary on both balancers
curl -s -c jar.txt -b jar.txt http://localhost:8080/stickyfailover/messages | grep -o '"host":"[^"]*"'
curl -s -c jars.txt -b jars.txt http://localhost:8080/stickyfailover-strict/messages | grep -o '"host":"[^"]*"'

docker compose --profile stickyfailover stop node-backend-sf-primary
# the first request after the stop is the nondeterministic transition - discard it
curl -s -c jar.txt -b jar.txt http://localhost:8080/stickyfailover/messages >/dev/null || true
curl -s -c jars.txt -b jars.txt http://localhost:8080/stickyfailover-strict/messages >/dev/null || true

# default: the session moved - every response from the standby
curl -s -c jar.txt -b jar.txt http://localhost:8080/stickyfailover/messages | grep -o '"host":"[^"]*"'
# strict: the session broke - 503
curl -s -o /dev/null -w '%{http_code}\n' -b jars.txt http://localhost:8080/stickyfailover-strict/messages

docker compose --profile stickyfailover up -d --wait node-backend-sf-primary
# default: still the standby (the cookie was rewritten); strict: the primary again
curl -s -c jar.txt -b jar.txt http://localhost:8080/stickyfailover/messages | grep -o '"host":"[^"]*"'
curl -s -b jars.txt http://localhost:8080/stickyfailover-strict/messages | grep -o '"host":"[^"]*"'

curl -k https://localhost:8443/stickyfailover/messages   # same routes over TLS
docker compose --profile stickyfailover down
```

The two recovery landings are the point of the demo and are deterministic —
the cookie's route decides, not scheduling.

## Tests

`scripts/smoke.sh` is the test suite. It builds the stack, starts the
requested profiles, waits until every container reports healthy, exercises
each route, then tears the stack down again. All checks run even if an earlier
one failed, and any failure exits non-zero:

```sh
scripts/smoke.sh               # all nine profiles — 55 checks
scripts/smoke.sh java node     # any subset
```

It generates the dev certificate itself if `reverse-proxy/certs/server.crt`
is missing, so it is also the one-command verification of a fresh clone.

CI (`.github/workflows/ci.yml`) runs a single job on every push to `master`
and on pull requests: set up buildx, generate the certificate, build five
distinct images — the `balanced` replicas, the `failover` pair, the
`sticky` pair, the `busy` pair and the `stickyfailover` pair are eleven
services sharing the single node image — with GitHub Actions layer caching
(merged from `.github/compose.cache.yml`), then run `scripts/smoke.sh`.

The Java backend additionally has `@WebMvcTest` unit tests
(`backends/java/src/test/`). Its image build runs `mvn package` without
`-DskipTests`, so building `java-backend` is itself the test run.

## Configuration model

- `reverse-proxy/httpd.conf` — trimmed base config, Apache 2.4-only syntax,
  18 modules. Serves the landing page, logs to stdout/stderr, and pulls in
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
  - `25-failover.conf` — the hot-standby pair: `<Proxy "balancer://failover">`
    with `node-backend-primary` (`retry=5`) and `node-backend-standby`
    (`retry=0 status=+H`) and the `/failover/` `ProxyPass`/`ProxyPassReverse`
    pair. The primary's `retry=5` is deliberate: hot standby engages through
    the worker error state, which `retry=0` would wipe (standby never
    activates). Same worker-parameters rule as 24: worker parameters live on
    the `BalancerMember` lines, not the balancer `ProxyPass`.
  - `26-sticky.conf` — session affinity: `<Proxy "balancer://sticky">` with
    two `BalancerMember` lines carrying `route=node-backend-sticky-1/2`
    (each matching that service's `ROUTE` env var and `hostname:`), plus
    `ProxySet stickysession=SESSIONID` — the balancer routes by the
    `.`-suffix of the client's `SESSIONID` cookie.
    `scolonpathdelim=On` additionally lets the same id arrive as the
    servlet-style path parameter `;SESSIONID=...` (the query-string form
    needs nothing); a URL parameter takes precedence over the cookie. Same
    worker-parameters rule as 24: worker parameters live on the
    `BalancerMember` lines, not the balancer `ProxyPass`.
  - `27-busy.conf` — the bybusyness pair: `<Proxy "balancer://busy">` with
    two `BalancerMember` lines and `ProxySet lbmethod=bybusyness`, plus the
    `/busy/` `ProxyPass`/`ProxyPassReverse` pair. Same worker-parameters rule
    as 24: `retry=0` lives on the `BalancerMember` lines, not the balancer
    `ProxyPass`.
  - `28-stickyfailover.conf` — sticky hot standby: TWO `<Proxy>` blocks over
    the same member pair; `balancer://stickyfailover` is the default
    (a pinned session fails over to the standby and stays there after
    recovery) and `balancer://stickyfailover-strict` adds `nofailover=On`
    (a pinned session breaks with 503 instead). Worker parameters on the
    `BalancerMember` lines, same rule as 24.
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
  and the three balanced replicas (`node-backend-1/2/3`), the failover
  pair (`node-backend-primary`/`node-backend-standby`), the sticky
  pair (`node-backend-sticky-1`/`-2`), the busy pair
  (`node-backend-busy-1`/`-2`) and the stickyfailover pair
  (`node-backend-sf-primary`/`-standby`) probe `http://127.0.0.1/...`
  because their listeners are IPv4-only while busybox `wget` resolves
  `localhost` to `::1` first; `reverse-proxy` and `java-backend` use
  `localhost`. Every service sets `restart: unless-stopped`.

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

`docs/BACKLOG.md` is the product backlog: deferred and future work collected
from the design specs' out-of-scope sections.
