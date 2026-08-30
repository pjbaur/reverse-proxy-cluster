# Sticky Sessions + Failover Demo Design

**Date:** 2026-08-30
**Status:** approved by project owner
**Feature:** an optional, demonstrable route combining `stickysession` affinity
with a `status=+H` hot standby, in both its flavors — session failover
(default) and session break (`nofailover=On`).

## Problem

The `sticky` and `failover` demos exercise session affinity and hot standby in
isolation. Backlog item 1 (`docs/BACKLOG.md`, deferred in the sticky design of
2026-08-27) asks what happens when they interact: does pinning survive primary
failure, and where does the session land during recovery? The owner wants an
opt-in demo answering both questions, plus the `nofailover=On` contrast the
isolation demos cannot show.

## Verified Apache behavior (httpd 2.4.x source)

Design rests on three facts read from `modules/proxy/` on the 2.4.x branch,
not guessed:

1. Sticky route lookup (`find_route_worker` in `mod_proxy_balancer.c`) runs
   two passes: it first searches non-standby workers, and only if no active
   worker matches the cookie's route does it search standby workers.
2. `PROXY_WORKER_IS_USABLE` (`mod_proxy.h`) excludes error/disabled/stopped/
   shutdown/healthcheck-failed workers but **not** `PROXY_WORKER_HOT_STANDBY`.
   A healthy standby is therefore a valid sticky target.
3. With the default `nofailover=Off`, a pinned worker in error state means the
   request falls back to normal balancer election (the session moves); with
   `nofailover=On`, the session breaks instead — the request returns
   `HTTP_SERVICE_UNAVAILABLE` (503) to the client.

Consequences the demo will show:

- **Failover:** a session pinned to the primary moves to the standby when the
  primary enters error state. The node backend sets `Set-Cookie` on every
  response, so the moved session's cookie is rewritten to the standby's route
  — the pin follows the session to its new home.
- **Recovery (default):** after the primary returns, the failed-over session's
  cookie points at the standby. Sticky lookup pass one (actives) finds no
  match, pass two finds the standby, and the standby is *usable* — fact 2 —
  so the session **stays on the standby**. Only new, cookie-less clients go
  back to the primary. Recovery is not session migration.
- **Recovery (strict):** a pinned session that broke (503) through the outage
  keeps its cookie pointed at the primary the whole time, so it resumes on the
  primary the moment the worker leaves error state — the opposite landing
  spot from the default path.

Two `<Proxy balancer://...>` blocks over the same two host:port members are
two independent worker sets: each balancer tracks error state separately, so
each needs its own warm-through request during the outage choreography.

## Decision record

- **Topology: two named services** (`node-backend-sf-primary` and
  `node-backend-sf-standby`) under a new `stickyfailover` profile, per the
  convention that every demo is independently runnable and independently
  asserted. Rejected: three members (two active plus a spare) — richer, but
  it answers a different question (partial-capacity failover) and grows the
  smoke section; the two-member shape mirrors the existing `failover` demo
  and answers the backlog question exactly.
- **Two balancers, same services, config-only contrast.** `balancer://stickyfailover`
  (default, session moves) and `balancer://stickyfailover-strict`
  (`nofailover=On`, session breaks) share the two backend services; the
  contrast costs one extra `<Proxy>` block and one extra prefix, no extra
  containers.
- **`retry=5` on the primary, `retry=0` on the standby** — identical to
  `25-failover.conf`. The bounded error window is what activates the standby
  and what makes recovery feel instant; `retry=0` on the primary would wipe
  the error state and break hot standby.
- **Both members are routed** (`route=` + matching `ROUTE` env + `hostname:`),
  following the four-places rule from the sticky demo: route param, env var,
  service name, hostname key must all be identical. The standby needs a route
  because the default-path session that lands on it must be able to pin
  there — without it, that session would silently degrade to round-robin.
- **Naming: `stickyfailover` everywhere** — profile `stickyfailover`, prefixes
  `/stickyfailover/` and `/stickyfailover-strict/`, balancers
  `balancer://stickyfailover(-strict)`, services `node-backend-sf-primary`/
  `node-backend-sf-standby` (route strings stay short), site config
  `28-stickyfailover.conf` (next free number).
- **No new Apache modules** — `mod_proxy_balancer` and friends are already
  loaded for `24`–`27`.

## Design

### Compose services — `docker-compose.yml`

Two services, the `node-backend-sticky-N` shape (explicit `hostname:`, `ROUTE`
env for the jvmRoute-style cookie) with the failover roles:

```yaml
  node-backend-sf-primary:
    build: ./backends/node
    hostname: node-backend-sf-primary
    profiles: ["stickyfailover"]
    environment:
      ROUTE: node-backend-sf-primary
    restart: unless-stopped
    networks:
      - proxy-net
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/messages"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s

  node-backend-sf-standby:
    build: ./backends/node
    hostname: node-backend-sf-standby
    profiles: ["stickyfailover"]
    environment:
      ROUTE: node-backend-sf-standby
    restart: unless-stopped
    networks:
      - proxy-net
    healthcheck:   # identical to the primary's
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/messages"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s
```

### Proxy config — `reverse-proxy/apacheconf/sites/28-stickyfailover.conf`

```apache
# /stickyfailover/... and /stickyfailover-strict/... -> two balancers over
# the same primary/standby pair (Compose profile "stickyfailover"). Both are
# sticky (stickysession=SESSIONID, jvmRoute-style route= on each member);
# they differ only in what a pinned session does when its member dies:
#   balancer://stickyfailover        (default)  the session MOVES to the
#     standby, whose response rewrites the cookie, and it stays there after
#     the primary recovers (a healthy standby is a valid sticky target).
#   balancer://stickyfailover-strict (nofailover=On)  the session BREAKS -
#     503 - and its cookie keeps pointing at the primary, so it resumes
#     there on recovery.
# retry=5 on the primary keeps the bounded error window that activates the
# standby (retry=0 on the primary would wipe it); standby retry=0 for
# instant activation.
<Proxy "balancer://stickyfailover">
    BalancerMember "http://node-backend-sf-primary:8080" route=node-backend-sf-primary retry=5
    BalancerMember "http://node-backend-sf-standby:8080" route=node-backend-sf-standby retry=0 status=+H
    ProxySet lbmethod=byrequests stickysession=SESSIONID
</Proxy>
ProxyPass        "/stickyfailover/" "balancer://stickyfailover/"
ProxyPassReverse "/stickyfailover/" "balancer://stickyfailover/"

<Proxy "balancer://stickyfailover-strict">
    BalancerMember "http://node-backend-sf-primary:8080" route=node-backend-sf-primary retry=5
    BalancerMember "http://node-backend-sf-standby:8080" route=node-backend-sf-standby retry=0 status=+H
    ProxySet lbmethod=byrequests stickysession=SESSIONID nofailover=On
</Proxy>
ProxyPass        "/stickyfailover-strict/" "balancer://stickyfailover-strict/"
ProxyPassReverse "/stickyfailover-strict/" "balancer://stickyfailover-strict/"
```

No `httpd.conf` change: no new modules.

### Smoke choreography — `scripts/smoke.sh`

New `stickyfailover)` case; the default profile list gains `stickyfailover`.
Two cookie jars (temp dir alongside `STICKY_DIR`, removed in the existing
cleanup trap). One helper is added: `check_host_exact_jar <name> <url> <jar>
<expected-host>` — the jar-carrying sibling of `check_host_constant`,
asserting a *known* host (constancy is not enough here; the landing spots are
the point). The choreography, in order:

1. **Steady state.** `/stickyfailover/messages` JSON, `X-Forwarded-Proto`,
   https variant; unpinned client always on the primary
   (`check_host_exact`); `/stickyfailover-strict/messages` JSON.
2. **Pin before any failure.** Jar A on `/stickyfailover/` and jar B on
   `/stickyfailover-strict/`, each verified pinned to the primary
   (`check_host_constant`).
3. **Outage.** `docker compose stop node-backend-sf-primary`; warm each
   balancer through its transition request with the *pinned* client (jar A
   on the default balancer, jar B on the strict one). The first request
   after the stop is nondeterministic — DNS lookup failure or a long
   timeout — exactly as in the `failover` case; discard it. The pinned warm
   request is also what puts each balancer's primary worker into error
   state: a cookie-less warm request would be elected straight to the
   standby and never touch the dead primary, so on the strict balancer it
   would not create the 503 condition. Then:
   - default, jar A: every response from the standby
     (`check_host_exact_jar`) — the session moved;
   - default, cookie-less: the standby also serves;
   - strict, jar B: `503` (`check_status`) — the session broke;
   - strict, cookie-less: `200` from the standby — no session, no break.
4. **Recovery.** `docker compose up -d --wait` the primary (`--wait`
   outlasts the primary's 5 s retry window, the same timing argument as the
   `failover` case), then:
   - default, jar A: **still the standby** — the failed-over session never
     migrates home;
   - default, fresh client: the primary again;
   - strict, jar B: **the primary** — the strict session resumed where it
     broke.

Checks 4a and 4c are the demo's answer to the backlog question and are
deterministic — the cookie's route decides, not scheduling. Expected total
for the case: 14 checks (all-profile run goes 37 → 51).

### Documentation

- `README.md`: architecture table row, demo section for the profile, updated
  route table and total-check count.
- `CLAUDE.md`: project table row, `Structure` entries for the services and
  `28-stickyfailover.conf`, `Commands` profile examples, smoke check count,
  and — if the four-places/`retry` interplay produces a convention worth
  recording — a short convention note alongside the existing sticky and
  hot-standby notes.
- `docs/BACKLOG.md`: item 1 moves to "Shipped from this backlog".
- CI (`.github/workflows/ci.yml`, `.github/compose.cache.yml`): extend the
  profile list if they enumerate profiles; verify during planning.

## Testing

`scripts/smoke.sh stickyfailover` is the test. It builds from clean, runs the
full choreography above, and tears down; every assertion maps to one cell of
the behavior matrix in this document. The full `scripts/smoke.sh` must still
pass (all profiles) before commit, per the repo convention.

## Out of scope

Three-member topologies (two actives plus a spare), URL-embedded session ids
(backlog item 2), non-node balancer members (backlog item 3), and
`balancer-manager` for these two balancers (the dashboard is not needed to
observe routing here; the `host` JSON field carries the evidence).
