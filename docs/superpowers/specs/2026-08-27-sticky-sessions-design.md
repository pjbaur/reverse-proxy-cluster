# Sticky Sessions Demo Design

**Date:** 2026-08-27
**Status:** approved by project owner
**Feature:** an optional, demonstrable session-affinity (sticky sessions) configuration in the Apache reverse proxy.

## Problem

The stack demonstrates round-robin load balancing (`balanced`) and hot-standby
failover (`failover`), but every request is stateless — nothing shows a client
being pinned to one backend member across requests. The balancer-demo design
explicitly deferred sticky sessions (`route` params +
`stickysession=JSESSIONID`); this feature picks that up. The owner wants an
opt-in demo where a client holding a session cookie always reaches the same
member, while a cookie-less client still sees rotation.

## Decision record

- **Mechanism: `ProxySet stickysession=SESSIONID` plus per-member `route=`
  params.** Apache reads the cookie named by `stickysession`, splits its value
  on the first `.`, and treats the suffix as the route: a request whose cookie
  ends in `.node-backend-sticky-1` goes to that member. Minimal diff, the route
  is visible in `/balancer-manager`, consistent with `24-balanced.conf` /
  `25-failover.conf`. Rejected: a mod_rewrite chain (no balancer state) and
  URL-embedded session ids (`stickysession=SESSIONID|sessionid`, path-parameter
  style — no cookies, but an awkward and unrealistic curl demo).
- **The backend mints the cookie, jvmRoute-style.** Each sticky service gets a
  `ROUTE` env var; the node app emits
  `Set-Cookie: SESSIONID=<uuid>.<ROUTE>` only when the var is present. This
  mirrors real Tomcat/JVM deployments (the app bakes its worker route into the
  session id, which is exactly what the original `JSESSIONID` idea referenced).
  It keeps the proxy config pure balancer directives, the module count at 17,
  and every other profile untouched (no env var, no cookie).
  Rejected: the proxy-side mod_headers trick
  (`Header add Set-Cookie "BALANCEID=.%{BALANCER_WORKER_ROUTE}e"
  env=BALANCER_ROUTE_CHANGED`) — zero backend change, but it would add an
  18th module and leans on undocumented-feeling environment-variable magic
  that is harder to explain in a teaching demo.
- **Topology: two dedicated named services** — `node-backend-sticky-1` and
  `node-backend-sticky-2`, own profile `sticky`. Same reasoning as the failover
  demo: each demo independently runnable and independently asserted; mutating
  the finished `balanced` demo (e.g. adding a second profile to its replicas)
  would couple teardown and smoke expectations for no gain. Two members are
  enough to prove pinning — a third adds YAML, not lesson.
- **Cookie re-minted per response is fine.** The node app sets a fresh
  `<uuid>.<ROUTE>` cookie on every `/messages` response. The uuid changes but
  the route suffix never does, so affinity holds; keeping the handler
  stateless avoids session storage in a demo backend.

## Design

### Compose services

Two services under profile `sticky`, building the existing `./backends/node`
context, exact clone of the failover pair's shape plus the `ROUTE` env var:

```yaml
  node-backend-sticky-1:
    build: ./backends/node
    hostname: node-backend-sticky-1
    profiles: ["sticky"]
    environment:
      ROUTE: node-backend-sticky-1
    restart: unless-stopped
    networks:
      - proxy-net
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/messages"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s
```

(`node-backend-sticky-2` identical modulo name/hostname/ROUTE.) No published
ports, `127.0.0.1` health probe, explicit `hostname:` (the JSON `host` field
is the container hostname — a missing key shows the container ID), per project
convention.

### Backend — `backends/node/server.js`

The shared node backend gains a `ROUTE`-gated cookie. The JSON body is
unchanged; only the response headers differ when `ROUTE` is set:

```js
const crypto = require('node:crypto');
const route = process.env.ROUTE || null;

// inside the GET /messages handler:
const headers = { 'Content-Type': 'application/json' };
if (route) {
  headers['Set-Cookie'] = `SESSIONID=${crypto.randomUUID()}.${route}; Path=/`;
}
res.writeHead(200, headers);
```

`crypto.randomUUID()` is a Node builtin (≥ 14.17), so the backend stays
zero-dependency. `Path=/` because the backend serves `/messages` while the
client visits `/sticky/messages`. Profiles other than `sticky` never set
`ROUTE`, so their responses carry no `Set-Cookie`.

### httpd modules

None added — everything needed (`mod_proxy_balancer`,
`mod_lbmethod_byrequests`, `mod_slotmem_shm`) is already loaded. Module count
stays 17.

### Balancer configuration — `reverse-proxy/apacheconf/sites/26-sticky.conf`

One file, one topic, numeric prefix next after 25:

```apache
# /sticky/... -> balancer://sticky (session affinity, Compose profile
# "sticky"). stickysession=SESSIONID makes the balancer read the client's
# SESSIONID cookie, split the value on the first "." and route by the
# suffix; each member's route= must equal that service's ROUTE env var
# (the backend bakes it into the cookie, jvmRoute-style). Cookie-less
# clients fall through to plain round-robin.
<Proxy "balancer://sticky">
    BalancerMember "http://node-backend-sticky-1:8080" route=node-backend-sticky-1 retry=0
    BalancerMember "http://node-backend-sticky-2:8080" route=node-backend-sticky-2 retry=0
    ProxySet lbmethod=byrequests stickysession=SESSIONID
</Proxy>
ProxyPass        "/sticky/" "balancer://sticky/"
ProxyPassReverse "/sticky/" "balancer://sticky/"
```

All directives server-level, so the route works identically on :8080 and the
:443 vhost (established inheritance model). No new `<Location>`: the existing
`/balancer-manager` handler is global and will show the `sticky` balancer
with each member's route in its URL column, alongside `demo` and `failover`.
`retry=0` follows the project default — nothing here depends on error state.

**Demo flow:** `docker compose --profile sticky up -d --build`, then
`curl -c jar.txt -s localhost:8080/sticky/messages | grep host` repeatedly —
`host` is the same member every time, and `curl -v` shows
`Set-Cookie: SESSIONID=<uuid>.node-backend-sticky-N`. Without the jar
(`curl -s localhost:8080/sticky/messages`), the two members alternate —
cookie-less clients still get round-robin. A second jar pins independently
(it may land on either member, but it stays there). Same behaviour over
`https://localhost:8443`.

### smoke.sh

`sticky` joins the default profile list (full run becomes 7 profiles). New
helper next to `check_host_exact`:

```sh
# check_host_constant <name> <url> <jar> — fetches 6 times through a curl
# cookie jar; every response's "host" must be the same value (stickiness
# pins a client to one member; which member is not deterministic under
# byrequests, so constancy is the assertion, not identity).
```

Case block, 5 checks:

1. `GET /sticky/messages` → 200, body contains `"backend":"node"` (http).
2. Same over https.
3. **Rotation check:** existing `check_rotates` with no cookie jar — ≥ 2
   distinct hosts across 12 fetches (affinity must not break plain
   round-robin for cookie-less clients).
4. **Pinning check:** `check_host_constant` with jar A — 6 fetches, one
   constant host.
5. **Independence check:** `check_host_constant` with jar B — also constant
   (proves per-client affinity, not a global pin to one member).

Full-suite check count rises from 27 to 32 (4 proxy + 4 java + 3 nginx + 3
node + 3 python + 5 balanced + 5 failover + 5 sticky); `smoke.sh sticky`
alone = 9 (4 proxy + 5).

Jars are created under `$(mktemp -d)` and removed in the existing cleanup
path.

### CI

`.github/workflows/ci.yml` build step adds `--profile sticky`.
`.github/compose.cache.yml` gains `node-backend-sticky-1` and
`node-backend-sticky-2` entries sharing the existing `scope=node-backend`
(same build context).

### Docs

- README: architecture diagram gains the sticky branch; service and routes
  tables gain the two services and `/sticky/messages`; a short "Sticky
  sessions demo" walkthrough section (start, curl with jar, curl without,
  second jar); check-count references 27 → 32.
- CLAUDE.md: profile table gains `/sticky/` → `balancer://sticky`; Commands
  gains the sticky up/down; Structure bullet for `26-sticky.conf`;
  Conventions gains the affinity pattern (member `route=` must equal the
  service's `ROUTE` env var; the backend bakes it into the `SESSIONID`
  cookie suffix; stickiness degrades silently to round-robin if the two
  drift, so keep the pinning smoke checks).
- Landing page `htdocs/index.html`: route list gains `GET /sticky/messages`.

## Testing

- `httpd -t` in the rebuilt proxy container.
- `scripts/smoke.sh sticky` — 9 passed, 0 failed.
- `scripts/smoke.sh` full — 32 passed, 0 failed.
- Manual demo verification: the jar/no-jar/second-jar transcript above.
- CI run green on push (cache scope warm on the second run).

## Risks

- **Silent degradation:** a wrong cookie name, a missing `.` suffix, or a
  route/ROUTE mismatch produces no error — the balancer just falls back to
  round-robin. The pinning checks (4 and 5) are the only guard; if they fail,
  inspect the cookie with `curl -v` before touching the balancer.
- **check_rotates flake:** 12 cookie-less fetches over 2 members must hit
  both. Under byrequests alternation this is deterministic in practice —
  same confidence as the existing balanced check over 3 members.

## Out of scope

`bybusyness` (still queued from the balanced demo), URL-embedded session ids,
stickiness interacting with failover members, sticky sessions on non-node
backends, and more members.
