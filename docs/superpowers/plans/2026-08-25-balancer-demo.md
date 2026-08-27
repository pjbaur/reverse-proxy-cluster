# Load-Balancing Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `balanced` Compose profile demonstrating Apache `mod_proxy_balancer`: three named node replicas behind `/balanced/`, a protected `/balancer-manager` dashboard, smoke coverage, CI, and docs.

**Architecture:** Follows the established drop-in conventions exactly — server-level directives in a numbered `sites/` file, profile-gated compose services, config baked into the image. Balancing lives inside Apache where it is observable (JSON `host` rotation).

**Tech Stack:** Apache httpd 2.4 (`mod_proxy_balancer`, `mod_lbmethod_byrequests`, `mod_slotmem_shm`), Docker Compose profiles, existing node backend image reused unchanged.

**Spec:** `docs/superpowers/specs/2026-08-25-balancer-demo-design.md` (approved).

## Global Constraints

- Apache 2.4-only syntax; server-level directives only (no new vhosts); `retry=0` on every worker/proxy directive.
- Healthchecks probe `127.0.0.1`, live in docker-compose.yml only.
- No published ports for backends; everything reachable via the proxy (8080/8443).
- gha cache entries carry `scope=`; the three replicas share scope `node-backend`.
- Conventional commits; each task ends verified and committed; run the relevant smoke subset before committing.
- Module-count references must end consistent at **17** everywhere they appear (httpd.conf comment, README, CLAUDE.md).
- Full-suite smoke expectation after this feature: **22 passed, 0 failed**; `balanced`-alone: **9** (4 proxy + 5 balanced).

---

## Task 1: Balancer core (compose services, httpd modules, 24-balanced.conf)

**Files:**
- Modify: `docker-compose.yml` (append three services after `python-backend`)
- Modify: `reverse-proxy/httpd.conf` (module block + count comment)
- Create: `reverse-proxy/apacheconf/sites/24-balanced.conf`

**Interfaces:**
- Produces: profile `balanced` with services `node-backend-1`, `node-backend-2`, `node-backend-3` (DNS names on `proxy-net`, port 8080); route `GET /balanced/messages` → `{"backend":"node",...,"host":"<replica>",...}`; `GET /balancer-manager` → dashboard. Consumed by Tasks 2 (smoke) and 3 (docs).

- [x] **Step 1: Append three services to `docker-compose.yml`**

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

`node-backend-2` and `node-backend-3`: identical, only the service-name key differs.

- [x] **Step 2: Edit `reverse-proxy/httpd.conf` module block** — after the `proxy_http` pair add:

```apache
# load balancing (slotmem backs the balancer's shared worker state)
LoadModule slotmem_shm_module modules/mod_slotmem_shm.so
LoadModule proxy_balancer_module modules/mod_proxy_balancer.so
LoadModule lbmethod_byrequests_module modules/mod_lbmethod_byrequests.so
```

Update the module-count comment from 14 to 17 (it reads `# --- modules (14: incl. TLS pair socache_shmcb + ssl) ...` — rewrite as `# --- modules (17: proxy core+balancer, TLS pair, status, headers) -------` or similar accurate wording).

- [x] **Step 3: Create `reverse-proxy/apacheconf/sites/24-balanced.conf`**

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

- [x] **Step 4: Verify**

```sh
docker compose --profile balanced up -d --build --wait
docker compose ps                      # 4 services: reverse-proxy + 3 replicas, all (healthy)
docker compose exec reverse-proxy httpd -t        # Syntax OK
docker compose exec reverse-proxy httpd -M | grep -c 'balancer\|lbmethod\|slotmem'   # 3
curl -fsS http://localhost:8080/balanced/messages | grep -q '"backend":"node"' && echo ROUTE-OK
for i in 1 2 3 4 5 6; do curl -fsS http://localhost:8080/balanced/messages | grep -o '"host":"[^"]*"'; done
   # at least 2 distinct hosts across 6 requests
curl -kfsS https://localhost:8443/balanced/messages | grep -q '"backend":"node"' && echo TLS-OK
curl -fsS http://localhost:8080/balancer-manager | grep -qi "Load Balancer Manager" && echo MANAGER-OK
docker compose --profile balanced down --remove-orphans
```

**Known risk + fallback:** if `httpd -t` rejects `ProxyPassReverse "/balanced/" "balancer://demo/"`, drop the `ProxyPassReverse` line entirely (Location headers from these backends are absolute-path-free JSON responses; the directive is convention here, not function) and note the deviation in the report. Do not substitute per-member ProxyPassReverse lines.

- [x] **Step 5: Commit**

```
feat(proxy): balanced profile demo with mod_proxy_balancer

- three named node replicas under Compose profile "balanced"
- sites/24-balanced.conf: balancer://demo (byrequests, retry=0) + protected
  /balancer-manager dashboard
- httpd.conf: load slotmem_shm, proxy_balancer, lbmethod_byrequests (17 modules)
```

---

## Task 2: smoke + CI coverage

**Files:**
- Modify: `scripts/smoke.sh` (default profile list + `balanced` case block)
- Modify: `.github/compose.cache.yml` (three services, shared scope)
- Modify: `.github/workflows/ci.yml` (build profile flag)

**Interfaces:**
- Consumes: route + dashboard from Task 1 (`/balanced/messages`, `/balancer-manager`).
- Produces: full-suite expectation 22 passed / 0 failed; `smoke.sh balanced` → 9.

- [x] **Step 1: Edit `scripts/smoke.sh`** — change the default line to:

```sh
  PROFILES="java nginx node python balanced"
```

- [x] **Step 2: Add a rotation helper + case block.** Helper (place after `check_status`):

```sh
# check_rotates <name> <url> <min-distinct> — fetches 12 times, counts
# distinct "host" values; round-robin over 3 members must spread >= 2.
check_rotates() {
  name="$1"; url="$2"; min="$3"
  hosts=""
  i=0
  while [ "$i" -lt 12 ]; do
    h="$(curl -fsS "$url" 2>/dev/null | sed -n 's/.*"host":"\([^"]*\)".*/\1/p')" || h=""
    hosts="$hosts $h"
    i=$((i + 1))
  done
  distinct="$(for h in $hosts; do [ -n "$h" ] && echo "$h"; done | sort -u | grep -c .)"
  if [ "${distinct:-0}" -ge "$min" ]; then
    ok "$name"
  else
    failed "$name - only $distinct distinct hosts (wanted >= $min) from $url"
  fi
}
```

Case inside the profile loop (after `python)`):

```sh
    balanced)
      check "balanced: /balanced/messages"                "$BASE_HTTP/balanced/messages"   '"backend":"node"'
      check "balanced: X-Forwarded-Proto=http"            "$BASE_HTTP/balanced/messages"   '"x_forwarded_proto":"http"'
      check "balanced: /balanced/messages over https"     "$BASE_HTTPS/balanced/messages"  '"backend":"node"' -k
      check_rotates "balanced: host rotation (>=2 of 3)"  "$BASE_HTTP/balanced/messages"   2
      check "balanced: balancer-manager dashboard"        "$BASE_HTTP/balancer-manager"    "Load Balancer Manager"
      ;;
```

(Update the header comment's profile list if it names the defaults.)

- [x] **Step 3: Extend `.github/compose.cache.yml`** — add:

```yaml
  node-backend-1:
    build:
      context: ./backends/node
      cache_from: ["type=gha,scope=node-backend"]
      cache_to: ["type=gha,mode=max,scope=node-backend"]
  node-backend-2:
    build:
      context: ./backends/node
      cache_from: ["type=gha,scope=node-backend"]
      cache_to: ["type=gha,mode=max,scope=node-backend"]
  node-backend-3:
    build:
      context: ./backends/node
      cache_from: ["type=gha,scope=node-backend"]
      cache_to: ["type=gha,mode=max,scope=node-backend"]
```

- [x] **Step 4: Edit `.github/workflows/ci.yml`** — build step profile list gains `--profile balanced`.

- [x] **Step 5: Verify**

```sh
sh -n scripts/smoke.sh && echo SYNTAX-OK
docker compose -f docker-compose.yml -f .github/compose.cache.yml \
  --profile java --profile nginx --profile node --profile python --profile balanced config -q && echo MERGE-OK
scripts/smoke.sh balanced    # 9 passed, 0 failed
scripts/smoke.sh             # 22 passed, 0 failed
```

- [x] **Step 6: Commit**

```
test: smoke and CI coverage for the balanced profile

- smoke.sh: balanced case (route http+https, rotation >=2 distinct hosts
  over 12 requests, balancer-manager), default profiles now 5
- CI builds the balanced profile; replicas share gha cache scope node-backend
```

---

## Task 3: Docs (README, CLAUDE.md, landing page)

**Files:**
- Modify: `README.md`, `CLAUDE.md`, `reverse-proxy/apacheconf/htdocs/index.html`

**Interfaces:** Consumes Tasks 1-2 (route, dashboard, 22-check suite).

- [x] **Step 1: README.md** — architecture diagram gains the balanced branch (proxy → balancer://demo → node-backend-1/2/3, profile `balanced`); service table gains the three replicas (profile `balanced`, route `/balanced/`); routes table gains `GET /balanced/messages` (JSON; `host` shows which replica) and `GET /balancer-manager` (dashboard, loopback+RFC1918); new short section "Load-balancing demo" (start command, repeated curl showing rotating `host`, manager URL, drain-a-member trick, https variant); check-count references 17 → 22; module count 14 → 17 wherever stated; configuration-model bullet for `24-balanced.conf`.
- [x] **Step 2: CLAUDE.md** — profile table gains `/balanced/` → `balancer://demo` (profile `balanced`, 3× node replicas); Commands gain the balanced up/down; Structure bullet for `24-balanced.conf`; Conventions gains: balancer members must be named services (DNS resolves once at start — `--scale` breaks `BalancerMember`); module count 14 → 17.
- [x] **Step 3: Landing page** — `htdocs/index.html` route list gains `<li><code>GET /balanced/messages</code> — load-balanced across 3 node replicas (<code>--profile balanced</code>)</li>` (match existing markup).
- [x] **Step 4: Verify** — `docker compose --profile balanced up -d --build --wait` (rebuild picks up new landing page), `curl -fsS http://localhost:8080/ | grep -q balanced`, spot-check every documented claim against files (`grep -c LoadModule reverse-proxy/httpd.conf` = 17), `scripts/smoke.sh balanced` still 9/0, `docker compose --profile balanced down --remove-orphans`.
- [x] **Step 5: Commit**

```
docs: document the balanced profile load-balancing demo
```

---

## Verification (end-to-end)

1. `scripts/smoke.sh` — **22 passed, 0 failed**, clean teardown.
2. Manual demo: repeated `curl localhost:8080/balanced/messages` shows 3 distinct hosts; `/balancer-manager` renders three members.
3. Push; CI green (build step now includes `--profile balanced`; second run warm via `scope=node-backend`).
4. `grep -rn "14 modules\|modules (14" README.md CLAUDE.md reverse-proxy/httpd.conf` — no stale count.

## Risks & Fallbacks

- `ProxyPassReverse` with `balancer://` scheme — syntax-checked by `httpd -t`; fallback: drop the line (documented in Task 1).
- Rotation flake in CI — 12 draws over 3 round-robin members, threshold ≥2; effectively deterministic.
- Healthcheck IPv6 trap — pre-empted by `127.0.0.1` probes.
