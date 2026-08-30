# Bybusyness Demo Design

**Date:** 2026-08-29
**Status:** approved by project owner
**Feature:** an optional, demonstrable `lbmethod=bybusyness` load-balancing route contrasting with the existing `byrequests` round-robin.

## Problem

The stack demonstrates `byrequests` round-robin (`balanced` profile) but no
other lbmethod. `bybusyness` was deferred in the balancer-demo design
(2026-08-25), re-deferred by the failover and sticky designs, and now sits at
the top of `docs/BACKLOG.md`. The owner wants an opt-in demo showing the one
Apache behavior the repo still lacks: a balancer that routes by *in-flight
work* instead of by request count.

## Decision record

- **Mechanism: `ProxySet lbmethod=bybusyness`** inside a new
  `balancer://busy`. `bybusyness` elects the member with the fewest active
  requests (normalized by `lbfactor`), so it visibly avoids a member that is
  holding a long request — the exact blind spot of `byrequests`, which
  alternates by count and keeps sending to the busy member. Observable in
  `/balancer-manager` (the elected-count column diverges while a slow request
  is in flight).
- **How the demo creates busyness: `?delay=<ms>` query parameter on
  `/messages`** in the node backend. A request with `?delay=3000` holds a
  member busy for 3 s with zero new dependencies. Rejected: a dedicated
  `/slow` endpoint (same mechanics, more surface — new path, healthcheck and
  contract docs to touch) and a parallel-burst demo with no backend change
  (non-deterministic, and the requests finish too fast for active counts to
  ever differ — it demonstrates nothing).
- **Contrast assertion is self-normalizing.** The smoke check fires one
  `?delay=3000` request in the background, captures *which member answered it*
  from the response body, then fires four sequential fast requests while the
  slow one is still in flight. Under `bybusyness` all four return the *same*
  other member (0 active vs 1). Under `byrequests` the four alternate
  strictly between both members, so the constancy assertion fails. No
  assumption about BalancerMember order or prior balancer state — whichever
  member took the slow request, the check discriminates the two methods.
- **Topology: two named services** (`node-backend-busy-1/2`) under a new
  `busy` profile, per the convention that every demo is independently
  runnable and independently asserted. Reusing the `balanced` members would
  hang a second demo off a finished profile and double its smoke section.
- **`retry=0` on both members.** No failure story in this demo; `retry=0`
  keeps a stopped member re-elected immediately, matching `24-balanced.conf`.
- **Naming: `busy` everywhere** — route `/busy/`, balancer `balancer://busy`,
  profile `busy`, services `node-backend-busy-1/2`, site config
  `27-busy.conf` — matching the short prefixes `/balanced/`, `/failover/`,
  `/sticky/`.

## Design

### Backend change — `backends/node/server.js`

`/messages` gains an optional `delay` query parameter:

```js
const params = new URL(req.url, 'http://localhost').searchParams;
const delayMs = Math.min(Math.max(parseInt(params.get('delay'), 10) || 0, 0), 10000);
```

The response is written after `setTimeout(delayMs)`; `delayMs` 0 (absent,
non-numeric, negative) responds exactly as today. Upper clamp 10 s keeps a
mistyped value from wedging smoke. Body, cookie logic, 404 handling, and the
port are untouched. The node image is shared by the `node`, `balanced`,
`failover`, `sticky`, and `busy` profiles — the change is additive, so no
existing behavior or smoke expectation moves.

### Compose services — `docker-compose.yml`

Two services, exact clone of the `node-backend-N` shape (explicit
`hostname:` so the JSON `host` field reads cleanly):

```yaml
  node-backend-busy-1:
    build: ./backends/node
    hostname: node-backend-busy-1
    profiles: ["busy"]
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

(`node-backend-busy-2` identical modulo the name/hostname.) No published
ports, `127.0.0.1` health probe, per project convention. Service count
12 → 14.

### httpd modules — `reverse-proxy/httpd.conf`

One new line:

```apache
LoadModule lbmethod_bybusyness_module modules/mod_lbmethod_bybusyness.so
```

Module count 17 → 18; the count comment in `httpd.conf` and the counts in
README and CLAUDE.md are updated to 18.

### Balancer configuration — `reverse-proxy/apacheconf/sites/27-busy.conf`

Next free numeric prefix; server-level directives only:

```apache
# /busy/... -> balancer://busy (two node members, Compose profile "busy").
# lbmethod=bybusyness elects the member with the fewest active requests,
# so a member holding a long request (?delay=ms) is skipped until it
# finishes — the contrast with byrequests round-robin in 24-balanced.conf.
# (retry=0 lives on the BalancerMember lines: on a balancer:// ProxyPass,
# key=value params are balancer params and httpd rejects worker params here.)
<Proxy "balancer://busy">
    BalancerMember "http://node-backend-busy-1:8080" retry=0
    BalancerMember "http://node-backend-busy-2:8080" retry=0
    ProxySet lbmethod=bybusyness
</Proxy>
ProxyPass        "/busy/" "balancer://busy/"
ProxyPassReverse "/busy/" "balancer://busy/"
```

Server-level placement means the route works identically on :8080 and the
:443 vhost (established inheritance model). No new `<Location>`: the global
`/balancer-manager` handler will show `balancer://busy` alongside
`balancer://demo` and the others.

**Demo flow:** `docker compose --profile busy up -d --build`, then in one
terminal `curl localhost:8080/busy/messages?delay=3000` and, while it hangs,
`curl localhost:8080/busy/messages` a few times in another — every fast
answer shows the *other* member's `host`. The same contrast over
`https://localhost:8443`; `/balancer-manager` shows the elected counts
diverging while the slow request runs.

### smoke.sh — `scripts/smoke.sh`

`busy` joins the default profile list (full run becomes 8 profiles). New
helper next to the other host-based checks:

```sh
# check_avoids_busy <name> <url> — fires one background ?delay=3000
# request, then 4 sequential fast ones while it is in flight; every fast
# response's "host" must be identical and differ from the slow one's
# (bybusyness skips the member holding the slow request; byrequests would
# alternate, failing constancy).
```

The helper sleeps ~0.3 s after launching the background curl (dispatch
settles), captures the slow response body to a temp file for its `host`,
runs the four fast fetches, then `wait`s the background curl (bounded by
the 3 s delay) before asserting. Case block, 5 checks:

1. `GET /busy/messages` → 200, body contains `"backend":"node"` (http).
2. `X-Forwarded-Proto=http` echoed through the busy route.
3. Same over https.
4. `GET /busy/messages?delay=500` → 200 with the same JSON shape (delay
   honored; no timing assertion — wall-clock asserts flake in CI).
5. **Contrast check:** `check_avoids_busy` as above.

Full-suite check count rises from 32 to 37; `smoke.sh busy` alone = 9
(4 proxy + 5). The helper's temp file and background curl are covered by the
existing cleanup trap path.

### CI

`.github/workflows/ci.yml` build step adds `--profile busy`.
`.github/compose.cache.yml` gains `node-backend-busy-1` and
`node-backend-busy-2` entries sharing the existing `scope=node-backend`
(same build context).

### Docs

- README: route table gains `/busy/` → `balancer://busy`; module count
  17 → 18; check-count references 32 → 37; a short "Busy-demo (bybusyness)"
  walkthrough section mirroring the failover/sticky sections (start, hang a
  slow curl, fire fast curls, observe the other member, `/balancer-manager`
  note).
- CLAUDE.md: profile table gains the `/busy/` row; Commands gains the busy
  up/down; Structure bullets gain `27-busy.conf` and the delay parameter
  note; service count 12 → 14; module count 17 → 18 (the balancer cost three
  modules, bybusyness a fourth).
- Landing page `reverse-proxy/apacheconf/htdocs/index.html`: route list gains
  `GET /busy/messages`.
- `docs/BACKLOG.md`: item 1 (`bybusyness` contrast) moves from Open to
  Shipped.

## Testing

- `httpd -t` in the rebuilt proxy container (implied by smoke build).
- `scripts/smoke.sh busy` — 9 passed, 0 failed (includes the live contrast
  check).
- `scripts/smoke.sh` full — 37 passed, 0 failed.
- Manual demo verification: the two-terminal curl transcript above.
- CI green on push (cache scope warm on the second run).

## Risks

- **Node serves concurrently, so "busy" is a balancer-metric artifact by
  design.** A slow request does not block the node event loop; member 1
  *could* answer fast requests fine. The demo shows the balancer's routing
  decision (avoid in-flight load), not backend saturation — that is the
  honest, observable contrast between the two lbmethods and the README
  section should say so plainly.
- **Contrast-check timing.** The 4 fast fetches (~tens of ms each) must land
  inside the 3 s delay window after a 0.3 s settle — ample margin even on a
  loaded CI runner. If the window is ever raced, raise the delay, never
  lower the settle.
- **Prior balancer state.** The check asserts against the slow request's
  captured host, not a hardcoded member, so earlier checks hitting `/busy/`
  cannot skew it.

## Out of scope

Non-node members in a balancer, combining bybusyness with sticky or failover
members, more members, and Swarm integration — all remain queued in
`docs/BACKLOG.md`.
