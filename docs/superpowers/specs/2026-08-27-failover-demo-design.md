# Failover Demo Design

**Date:** 2026-08-27
**Status:** approved by project owner
**Feature:** an optional, demonstrable hot-standby failover configuration in the Apache reverse proxy.

## Problem

The stack now demonstrates round-robin load balancing (`balanced` profile), but every
member there is interchangeable — nothing shows what happens when a backend *dies*.
The balancer-demo design explicitly deferred hot-standby tuning; this feature picks
that up. The owner wants an opt-in demo where stopping the serving backend visibly
shifts traffic to a standby and back on recovery.

## Decision record

- **Mechanism: per-member `status=+H` (hot standby)** inside `balancer://failover`.
  A member marked `H` receives traffic only when every non-standby member is in
  error state. Minimal diff, semantics visible in `/balancer-manager` (the "St"
  column shows the mark), consistent with `24-balanced.conf`. Rejected:
  `ProxySet failover=on` (balancer-level flag, newer, coarser, identical observable
  result for two members) and a mod_rewrite proxy chain (no balancer state, nothing
  to observe in the manager, needless complexity).
- **Topology: two named services** — `node-backend-primary` (serves everything while
  healthy) and `node-backend-standby` (idle until primary fails). Two members keep
  the story pure failover; mixing active round-robin with a standby would blur the
  lesson and its smoke assertions.
- **Separate profile `failover`**, not an extension of `balanced`. Each demo stays
  independently runnable and independently asserted; mutating the finished balanced
  demo would change its smoke expectations for no gain.
- **Backend: node**, same reasons as the balanced demo — fastest start, and the
  `/messages` JSON `host` field makes *which member answered* directly observable.
- **Smoke does a live stop + restart of the primary.** A failover demo that never
  kills anything demonstrates nothing. The suite stops the primary container
  mid-run, asserts the standby serves, restarts the primary, asserts recovery.
- **Retry split (corrected during implementation):** the primary
  `BalancerMember` carries `retry=5`, the standby `retry=0`, the
  `ProxyPass` pair nothing. Hot standby activates only while the primary's
  worker sits in error state — `retry=0` (the project's usual convention)
  wipes that state instantly, so every request re-elects the dead primary
  and returns 503 (measured; log shows `disabling worker ... for 0s`).
  `retry=5` keeps a bounded error window: standby serves the moment the
  primary fails, and the primary is re-elected within 5 s of returning.
  The plain per-backend `ProxyPass` routes keep `retry=0` — nothing there
  depends on error state.

## Design

### Compose services

Two services under profile `failover`, building the existing `./backends/node`
context, exact clone of the `node-backend-N` shape:

```yaml
  node-backend-primary:
    build: ./backends/node
    profiles: ["failover"]
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

(`node-backend-standby` identical modulo the service name.) No published ports,
`127.0.0.1` health probe, per project convention.

### httpd modules

None added — `mod_proxy_balancer`, `mod_lbmethod_byrequests`, `mod_slotmem_shm` are
already loaded. Module count stays 17.

### Balancer configuration — `reverse-proxy/apacheconf/sites/25-failover.conf`

One file, one topic, numeric prefix next after 24:

```apache
# /failover/... -> balancer://failover (active primary + hot standby,
# Compose profile "failover"). The primary serves everything while healthy;
# the standby (H) answers only while the primary is in error state.
# Primary retry=5 keeps a bounded error window so the standby activates
# and the primary recovers within 5 s (retry=0 on the primary wipes the
# error state and breaks hot standby); standby retry=0 for instant
# activation.
<Proxy "balancer://failover">
    BalancerMember "http://node-backend-primary:8080" retry=5
    BalancerMember "http://node-backend-standby:8080" retry=0 status=+H
    ProxySet lbmethod=byrequests
</Proxy>
ProxyPass        "/failover/" "balancer://failover/"
ProxyPassReverse "/failover/" "balancer://failover/"
```

All directives server-level, so the route works identically on :8080 and the :443
vhost (established inheritance model). No new `<Location>`: the existing
`/balancer-manager` handler is global and will show the `failover` balancer with
the standby's `H` mark alongside `balancer://demo`.

**Demo flow:** `docker compose --profile failover up -d --build`, then
`curl localhost:8080/failover/messages` repeatedly — `host` is always
`node-backend-primary`. `docker compose --profile failover stop node-backend-primary`
— the same curls now answer `host: node-backend-standby`. Restart the primary
(`docker compose --profile failover up -d --wait node-backend-primary`) and the
next requests return to the primary (the 5 s error window expires while the
healthcheck turns healthy). Same sequence works over `https://localhost:8443`;
`/balancer-manager` shows the standby's counts staying zero until the failover.

### smoke.sh

`failover` joins the default profile list (full run becomes 6 profiles). New helper
next to `check_rotates`:

```sh
# check_host_exact <name> <url> <expected-host> — fetches 6 times,
# every response's "host" must equal expected-host (failover is deterministic,
# unlike rotation).
```

Case block, 5 checks:

1. `GET /failover/messages` → 200, body contains `"backend":"node"` (http).
2. Same over https.
3. **Primary-serving check:** 6 requests, every `host` = `node-backend-primary`.
4. **Failover check:** `docker compose --profile failover stop node-backend-primary`,
   then 6 requests, every `host` = `node-backend-standby`.
5. **Recovery check:** `docker compose --profile failover up -d --wait
   node-backend-primary`, then 6 requests, every `host` = `node-backend-primary`
   (the `--wait` outlasts the 5 s error window, so the primary is re-elected
   immediately; recovery via `retry=5`).

Full-suite check count rises from 22 to 27 (4 proxy + 4 java + 3 nginx + 3 node +
3 python + 5 balanced + 5 failover); `smoke.sh failover` alone = 9 (4 proxy + 5).

The stop/restart commands reuse the profile set the suite already started, so
teardown in the existing cleanup path is unaffected.

### CI

`.github/workflows/ci.yml` build step adds `--profile failover`.
`.github/compose.cache.yml` gains `node-backend-primary` and `node-backend-standby`
entries sharing the existing `scope=node-backend` (same build context).

### Docs

- README: architecture diagram gains the failover branch; service and routes tables
  gain the two services and `/failover/messages`; a short "Failover demo" walkthrough
  section (start, curl, stop primary, curl, restart, curl); check-count references
  22 → 27.
- CLAUDE.md: profile table gains `/failover/` → `balancer://failover`; Commands gains
  the failover up/down; Structure bullet for `25-failover.conf`; Conventions gains
  the hot-standby pattern (mark the spare `status=+H`, keep `retry=0` for instant
  recovery).
- Landing page `htdocs/index.html`: route list gains `GET /failover/messages`.

## Testing

- `httpd -t` in the rebuilt proxy container.
- `scripts/smoke.sh failover` — 9 passed, 0 failed (includes the live stop/restart).
- `scripts/smoke.sh` full — 27 passed, 0 failed.
- Manual demo verification: the curl/stop/curl/restart transcript above.
- CI run green on push (cache scope warm on the second run).

## Risks

- **Recovery timing:** after `up -d --wait`, the node healthcheck may take up to
  ~15 s to flip healthy (interval 10 s). The recovery check polls with a bounded
  retry loop rather than assuming the first curl succeeds.
- **Standby not tried on connection-refused:** expected behavior is that a failed
  worker defers to the hot standby on the same request; if the live run shows 502s
  instead, escalate — do not paper over with retries in the check.

## Out of scope

`ProxySet failover=on` contrast, active health probes (`mod_proxy_hcheck`), sticky
sessions, `bybusyness`, standby for non-node backends, and more members. The
balanced demo's deferred items (sticky sessions, `bybusyness`) remain queued.
