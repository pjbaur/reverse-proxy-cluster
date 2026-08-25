# Load-Balancing Demo Design

**Date:** 2026-08-25
**Status:** approved by project owner
**Feature:** an optional, demonstrable load-balancing configuration in the Apache reverse proxy.

## Problem

The revived stack routes every prefix to exactly one backend (`ProxyPass` per profile). `mod_proxy_balancer` and the lbmethod modules were trimmed during the revival, so the repo named "reverse-proxy-**cluster**" cannot show balancing — the one Apache behavior it never demonstrates. The owner wants an opt-in way to show it.

## Decision record

- **Backend: node.** Lightest image, fastest start, and its `/messages` JSON already returns `host` (container hostname), which makes replica rotation directly observable in responses.
- **Topology: three named services** (`node-backend-1/2/3`) under a new Compose profile `balanced`. Named services give each `BalancerMember` a stable DNS name. `docker compose --scale` was rejected: `BalancerMember` resolves its host once at start, so a single DNS-round-robin name makes distribution unreliable. Docker Swarm was considered and rejected: `docker stack deploy` does not support Compose profiles (breaks the existing modularity), and Swarm's ingress mesh balances at L4 before httpd sees traffic, hiding the very behavior under demonstration.
- **Method: `lbmethod=byrequests`** (round-robin). Predictable host cycling is the clearest teaching story.
- **`/balancer-manager` included**, protected exactly like `/server-status` (loopback + RFC 1918). Live member counts and drain/disable controls are the demo's strongest payoff.
- **Deferred follow-up (queued story):** sticky sessions (`route` params + `stickysession=JSESSIONID`) and a `bybusyness` contrast. Not in this design.

## Design

### Compose services

Three services under profile `balanced`, all building the existing `./backends/node` context:

```yaml
  node-backend-1:
    build: ./backends/node
    profiles: ["balanced"]
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

(`node-backend-2`, `node-backend-3` identical modulo the service name.) Distinct service names give each replica its own DNS entry on `proxy-net`. No published ports, per project convention. Healthcheck probes `127.0.0.1` per the established convention.

### httpd modules

`reverse-proxy/httpd.conf` gains three `LoadModule` lines (14 → 17 total): `slotmem_shm_module` (shared worker-state memory the balancer needs), `proxy_balancer_module`, `lbmethod_byrequests_module`. The module-count comments in `httpd.conf`, README, and CLAUDE.md are updated to 17.

### Balancer configuration — `reverse-proxy/apacheconf/sites/24-balanced.conf`

One file, one topic, following the numeric-prefix convention:

```apache
# /balanced/... -> balancer://demo (three node replicas, Compose profile "balanced").
# Round-robin; the backend's JSON "host" field shows which member answered.
<Proxy "balancer://demo">
    BalancerMember "http://node-backend-1:8080" retry=0
    BalancerMember "http://node-backend-2:8080" retry=0
    BalancerMember "http://node-backend-3:8080" retry=0
    ProxySet lbmethod=byrequests
</Proxy>
ProxyPass        "/balanced/" "balancer://demo/" retry=0
ProxyPassReverse "/balanced/" "balancer://demo/"

# Live balancer dashboard: per-member counts, lbfactor, drain/disable controls.
# Same source restriction as /server-status.
<Location "/balancer-manager">
    SetHandler balancer-manager
    Require ip 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
</Location>
```

All directives are server-level, so the route and the manager work identically on :8080 and the :443 vhost (established inheritance model). `retry=0` everywhere, per project convention. If a replica's profile is not running, its prefix/request gets a 502 without affecting other routes.

**Demo flow:** `docker compose --profile balanced up -d --build`, then `curl localhost:8080/balanced/messages` repeatedly — `host` cycles through the three replica hostnames. Open `/balancer-manager` to see live counts; drain a member and watch traffic shift. Both also work over `https://localhost:8443`.

### smoke.sh

`balanced` joins the default profile list (full run becomes 5 profiles). New case block:

1. `GET /balanced/messages` → 200, body contains `"backend":"node"` (http).
2. Same over https.
3. **Rotation check:** 12 sequential requests collect the `host` values; at least 2 distinct values required (round-robin over 3 members makes this deterministic enough for CI; 12 draws avoid flake).
4. `GET /balancer-manager` → 200, body contains `Load Balancer Manager`.

Full-suite check count rises from 17 to 22 (4 proxy + 4 java + 3 nginx + 3 node + 3 python + 5 balanced).

### CI

`.github/workflows/ci.yml` build step adds `--profile balanced`. `.github/compose.cache.yml` gains `node-backend-1/2/3` entries; all three share one gha cache scope (`scope=node-backend`) since they build the identical context — the second and third builds become cache no-ops.

### Docs

- README: architecture diagram gains the balanced branch; routes table gains `/balanced/messages` and `/balancer-manager`; a short "Load-balancing demo" walkthrough section; check-count references updated.
- CLAUDE.md: backend table gains the `balanced` profile row; Conventions gains the balancer pattern (BalancerMembers must be named services, not scaled replicas); module count updated.
- Landing page `htdocs/index.html`: add the `/balanced/messages` route and profile to the list.

## Testing

- `httpd -t` in the rebuilt proxy container (syntax, incl. the 3 new modules).
- `scripts/smoke.sh balanced` — the new 5 checks plus the 4 proxy checks, green.
- `scripts/smoke.sh` full — 22 passed, 0 failed.
- Manual demo verification: repeated curls show rotating `host`; `/balancer-manager` renders with three members.
- CI run green on push.

## Out of scope

Sticky sessions, `bybusyness`, balancing any non-node backend, balancer failover tuning (`nofailover`, hot-standby), and Swarm integration.
