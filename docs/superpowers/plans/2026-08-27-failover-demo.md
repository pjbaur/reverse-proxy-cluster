# Failover Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `failover` Compose profile demonstrating Apache hot-standby failover: an active primary plus a `status=+H` standby behind `/failover/`, with a smoke suite that stops the primary mid-run and asserts takeover and recovery.

**Architecture:** Follows the established drop-in conventions exactly — server-level directives in a numbered `sites/` file, profile-gated compose services with explicit `hostname:` keys, config baked into the image. No new httpd modules; the balancer trio from the `balanced` demo is reused.

**Tech Stack:** Apache httpd 2.4 (`mod_proxy_balancer`, `mod_lbmethod_byrequests`, `mod_slotmem_shm` — all already loaded), Docker Compose profiles, existing node backend image reused unchanged.

**Spec:** `docs/superpowers/specs/2026-08-27-failover-demo-design.md` (approved).

## Global Constraints

- Apache 2.4-only syntax; server-level directives only (no new vhosts); `retry=0` on every worker/proxy directive — **except** the failover primary `BalancerMember`, which carries `retry=5`: `retry=0` wipes the worker error state, hot standby never activates, every request re-elects the dead primary (503 loop; discovered during Task 1 implementation).
- Healthchecks probe `127.0.0.1`, live in docker-compose.yml only.
- No published ports for backends; everything reachable via the proxy (8080/8443).
- gha cache entries carry `scope=`; both failover services share the existing scope `node-backend`.
- Conventional commits; each task ends verified and committed; run the relevant smoke subset before committing.
- Module count stays **17** (no `httpd.conf` changes in this feature).
- Full-suite smoke expectation after this feature: **27 passed, 0 failed**; `failover`-alone: **9** (4 proxy + 5 failover).
- Service names are load-bearing: `node-backend-primary` and `node-backend-standby` appear in `BalancerMember` URLs, in each service's `hostname:` key (so the JSON `host` field names the member — without `hostname:`, Docker's container ID would appear; see commit f0810ff), and in smoke assertions. Never rename one without the others.

---

## Task 1: Failover core (compose services + 25-failover.conf)

**Files:**
- Modify: `docker-compose.yml` (append two services after `node-backend-3`, before `networks:`)
- Create: `reverse-proxy/apacheconf/sites/25-failover.conf`

**Interfaces:**
- Produces: profile `failover` with services `node-backend-primary` and `node-backend-standby` (DNS names on `proxy-net`, port 8080); route `GET /failover/messages` → `{"backend":"node",...,"host":"node-backend-primary",...}` while the primary is up, `host: node-backend-standby` while it is stopped. Consumed by Tasks 2 (smoke) and 3 (docs).

- [ ] **Step 1: Append two services to `docker-compose.yml`**

After the `node-backend-3:` block (ends line 112, before `networks:`), append:

```yaml
  node-backend-primary:
    build: ./backends/node
    hostname: node-backend-primary
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

  node-backend-standby:
    build: ./backends/node
    hostname: node-backend-standby
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

Identical to the `node-backend-1` shape except the service name, `hostname:`, and `profiles: ["failover"]`.

- [ ] **Step 2: Create `reverse-proxy/apacheconf/sites/25-failover.conf`**

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

- [ ] **Step 3: Verify — including the live failover cycle**

```sh
docker compose --profile failover up -d --build --wait
docker compose ps    # 3 services: reverse-proxy + primary + standby, all (healthy)
docker compose exec reverse-proxy httpd -t        # Syntax OK
curl -fsS http://localhost:8080/failover/messages | grep -q '"backend":"node"' && echo ROUTE-OK
for i in 1 2 3 4 5 6; do curl -fsS http://localhost:8080/failover/messages | grep -o '"host":"[^"]*"'; done
   # all six lines: "host":"node-backend-primary"
curl -kfsS https://localhost:8443/failover/messages | grep -q '"backend":"node"' && echo TLS-OK
curl -fsS http://localhost:8080/balancer-manager | grep -q 'balancer://failover' && echo MANAGER-SHOWS-FAILOVER
   # (if this grep misses, grep for node-backend-standby instead and record
   #  the actual dashboard string — do not delete the check)
docker compose --profile failover stop node-backend-primary
for i in 1 2 3 4 5 6; do curl -fsS http://localhost:8080/failover/messages | grep -o '"host":"[^"]*"'; done
   # all six lines: "host":"node-backend-standby"  <-- the failover
docker compose --profile failover up -d --wait node-backend-primary
curl -fsS http://localhost:8080/failover/messages | grep -o '"host":"[^"]*"'
   # "host":"node-backend-primary" again          <-- the recovery
   # (the --wait outlasts the 5 s error window)
docker compose --profile failover down --remove-orphans
```

**Known risks:** If any curl during the stopped-primary phase returns 502/503 instead of the standby's JSON, stop and investigate — the hot-standby deferral is the feature; do not add retries to mask it. (Historical note: the original `retry=0` on the primary caused exactly this — see Global Constraints.) If `--wait` on the restart is slow, that is the healthcheck interval (10 s), not a bug; the wait is bounded by Compose's default timeout.

- [ ] **Step 4: Commit**

```
feat(proxy): failover profile demo with hot standby

- node-backend-primary + node-backend-standby under Compose profile
  "failover" (explicit hostname: so the JSON host names the member)
- sites/25-failover.conf: balancer://failover, standby marked status=+H;
  primary retry=5 keeps a bounded error window so the standby activates and
  the primary recovers within 5 s (retry=0 on the primary wipes the error
  state and breaks hot standby); no new modules (still 17)
```

---

## Task 2: smoke + CI coverage

**Files:**
- Modify: `scripts/smoke.sh` (header comment, default profile list, new helper, `failover` case block)
- Modify: `.github/compose.cache.yml` (two services, shared scope)
- Modify: `.github/workflows/ci.yml` (build profile flag)

**Interfaces:**
- Consumes: route + services from Task 1 (`/failover/messages`, `node-backend-primary`, `node-backend-standby`, profile `failover`).
- Produces: full-suite expectation 27 passed / 0 failed; `smoke.sh failover` → 9.

- [ ] **Step 1: Edit `scripts/smoke.sh` defaults.** Line 4 comment: `(default: all five)` → `(default: all six)`. Line 20:

```sh
  PROFILES="java nginx node python balanced failover"
```

- [ ] **Step 2: Add the `check_host_exact` helper** — place directly after `check_rotates` (after its closing `}` on line 73):

```sh
# check_host_exact <name> <url> <expected-host> — fetches 6 times; every
# response's "host" must equal expected-host. Failover is deterministic
# (unlike rotation), so any deviation is a failure.
check_host_exact() {
  name="$1"; url="$2"; want="$3"
  i=0; bad=0; empty=0
  while [ "$i" -lt 6 ]; do
    h="$(curl -fsS "$url" 2>/dev/null | sed -n 's/.*"host":"\([^"]*\)".*/\1/p')" || h=""
    if [ -z "$h" ]; then
      empty=$((empty + 1))
    elif [ "$h" != "$want" ]; then
      bad=$((bad + 1))
    fi
    i=$((i + 1))
  done
  if [ "$bad" -eq 0 ] && [ "$empty" -eq 0 ]; then
    ok "$name"
  else
    failed "$name - $bad wrong, $empty failed responses (wanted all '$want') from $url"
  fi
}
```

- [ ] **Step 3: Add the `failover` case block** — inside the profile loop, after the `balanced)` block (after its `;;`):

```sh
    failover)
      check "failover: /failover/messages"            "$BASE_HTTP/failover/messages"   '"backend":"node"'
      check "failover: /failover/messages over https" "$BASE_HTTPS/failover/messages"  '"backend":"node"' -k
      check_host_exact "failover: primary serves all"  "$BASE_HTTP/failover/messages"  node-backend-primary
      # shellcheck disable=SC2086
      if docker compose $PROFILE_ARGS stop node-backend-primary >/dev/null 2>&1; then
        check_host_exact "failover: standby takes over" "$BASE_HTTP/failover/messages" node-backend-standby
        # shellcheck disable=SC2086
        if docker compose $PROFILE_ARGS up -d --wait --wait-timeout 60 node-backend-primary >/dev/null 2>&1; then
          check_host_exact "failover: primary recovers" "$BASE_HTTP/failover/messages" node-backend-primary
        else
          failed "failover: primary did not come back healthy after restart"
        fi
      else
        failed "failover: could not stop node-backend-primary"
      fi
      ;;
```

Notes for the implementer: the script runs under `set -eu`, so the `docker compose` lifecycle commands sit inside `if` guards — a failure there must count as a failed check, not kill the suite. `$PROFILE_ARGS` is unquoted on purpose (word-splitting is how the flags reach compose); the existing `cleanup()` trap already tears the whole stack down, including the restarted primary.

- [ ] **Step 4: Extend `.github/compose.cache.yml`** — append after the `node-backend-3:` entry:

```yaml
  node-backend-primary:
    build:
      context: ./backends/node
      cache_from: ["type=gha,scope=node-backend"]
      cache_to: ["type=gha,mode=max,scope=node-backend"]
  node-backend-standby:
    build:
      context: ./backends/node
      cache_from: ["type=gha,scope=node-backend"]
      cache_to: ["type=gha,mode=max,scope=node-backend"]
```

- [ ] **Step 5: Edit `.github/workflows/ci.yml`** — the build step's profile list (line 26) gains `--profile failover`:

```yaml
            --profile java --profile nginx --profile node --profile python --profile balanced --profile failover \
```

- [ ] **Step 6: Verify**

```sh
sh -n scripts/smoke.sh && echo SYNTAX-OK
docker compose -f docker-compose.yml -f .github/compose.cache.yml \
  --profile java --profile nginx --profile node --profile python --profile balanced --profile failover config -q && echo MERGE-OK
scripts/smoke.sh failover    # 9 passed, 0 failed
scripts/smoke.sh             # 27 passed, 0 failed
```

- [ ] **Step 7: Commit**

```
test: smoke and CI coverage for the failover profile

- smoke.sh: failover case (route http+https, primary serves all, live
  stop -> standby takes over, restart -> primary recovers), default
  profiles now 6
- CI builds the failover profile; both services share gha cache scope
  node-backend
```

---

## Task 3: Docs (README, CLAUDE.md, landing page)

**Files:**
- Modify: `README.md`, `CLAUDE.md`, `reverse-proxy/apacheconf/htdocs/index.html`

**Interfaces:** Consumes Tasks 1-2 (route, services, 27-check suite).

- [ ] **Step 1: README.md** — nine edits:

1. Intro (lines 8-10): extend the fifth-profile sentence — after `— see [Load-balancing demo](#load-balancing-demo).` add:

```markdown
A sixth profile, `failover`, pairs an active primary with a hot standby at
`/failover/` — see [Failover demo](#failover-demo).
```

2. Architecture diagram: `balanced` branch stops being the last (`└─▶`) entry. Restructure lines 24-28 to:

```
                              ├─▶ /balanced/ ─▶ balancer://demo  (profile balanced)
                              │                 byrequests round-robin:
                              │                 ├─▶ node-backend-1 :8080
                              │                 ├─▶ node-backend-2 :8080
                              │                 └─▶ node-backend-3 :8080
                              └─▶ /failover/ ─▶ balancer://failover (profile failover)
                                                hot standby (status=+H):
                                                ├─▶ node-backend-primary :8080  ◀─ serves all
                                                └─▶ node-backend-standby :8080  ◀─ on error only
```

3. Service table: after the `node-backend-1 … 3` row add:

```markdown
| node-backend-primary, node-backend-standby | `node:22-alpine` (same build as `node-backend`) | `failover` | none | `/failover/` (via `balancer://failover`) |
```

4. Quickstart (line 61): "list all five profiles" → "list all six profiles"; the command gains `--profile failover`.

5. Routes table: after the `/balanced/messages` row add:

```markdown
| `GET /failover/messages` | `balancer://failover` | `failover` | JSON; `host` is `node-backend-primary`, or `-standby` while it is down |
```

6. New section between "Load-balancing demo" and "Tests":

````markdown
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

# kill the primary — the same requests now answer from the standby
docker compose --profile failover stop node-backend-primary
curl -s http://localhost:8080/failover/messages | grep -o '"host":"[^"]*"'

# restart the primary — traffic returns on the next request
docker compose --profile failover up -d --wait node-backend-primary
curl -s http://localhost:8080/failover/messages | grep -o '"host":"[^"]*"'

curl -k https://localhost:8443/failover/messages   # same route over TLS
docker compose --profile failover down
```

`/balancer-manager` lists both balancers; the `failover` members carry an
`H` flag and the standby's `Elected` count stays `0` until the failover.
````

7. Tests section (line 154): `# all five profiles — 22 checks` → `# all six profiles — 27 checks`.

8. Configuration model list: after the `24-balanced.conf` bullet add:

```markdown
  - `25-failover.conf` — the hot-standby pair: `<Proxy "balancer://failover">`
    with `node-backend-primary` (`retry=5`) and `node-backend-standby`
    (`retry=0 status=+H`) and the `/failover/` `ProxyPass`/`ProxyPassReverse`
    pair. The primary's `retry=5` is deliberate: hot standby engages through
    the worker error state, which `retry=0` would wipe (standby never
    activates). Same worker-parameters rule as 24: worker parameters live on
    the `BalancerMember` lines, not the balancer `ProxyPass`.
```

9. Healthchecks paragraph (lines 211-212): extend `and the three balanced replicas (`node-backend-1/2/3`)` to also name `the failover pair (`node-backend-primary`/`node-backend-standby`)`.

- [ ] **Step 2: CLAUDE.md** — five edits:

1. Project profile table: add row after the `/balanced/` row:

```markdown
| `/failover/` | `balancer://failover` → node-backend-primary/standby | `failover` | 2× node: hot standby (`status=+H`) |
```

2. Commands: the "every backend" example gains `--profile failover`; after the balanced line add:

```sh
docker compose --profile failover up -d --build   # hot-standby failover demo
```

3. Commands: the smoke-suite comment `(22 checks)` → `(27 checks)`.

4. Structure: extend the `apacheconf/sites/` bullet — after `24-balanced.conf (...)` add:

```markdown
  `25-failover.conf` (`balancer://failover` hot standby:
  `node-backend-primary` + `node-backend-standby` with `status=+H`)
```

5. Conventions: add bullet after the "Balancer members must be named services" bullet:

```markdown
- **Hot standby needs `status=+H`, `hostname:`, and a real error window.**
  Mark the spare `status=+H` so it serves only when the primary is in error
  state, give both services explicit `hostname:` keys (the JSON `host` field
  is the container hostname — a missing key shows the container ID), and keep
  the primary's retry small but nonzero (`retry=5`) — the error window is
  what activates the standby (`retry=0` wipes it; the standby never engages)
  and it expires fast enough that recovery feels instant.
```

- [ ] **Step 3: Landing page** — `reverse-proxy/apacheconf/htdocs/index.html`, after the `/balanced/messages` `<li>`:

```html
    <li><code>GET /failover/messages</code> — hot standby: primary serves, standby takes over when it stops (<code>--profile failover</code>)</li>
```

- [ ] **Step 4: Verify**

```sh
docker compose --profile failover up -d --build --wait    # rebuild picks up the landing page
curl -fsS http://localhost:8080/ | grep -q failover && echo LANDING-OK
grep -c '^LoadModule' reverse-proxy/httpd.conf            # 17
grep -rn '22 checks\|all five' README.md CLAUDE.md scripts/smoke.sh   # no hits
scripts/smoke.sh failover                                 # 9 passed, 0 failed
docker compose --profile failover down --remove-orphans
```

Then spot-check every documented claim against the files (service names, route, dashboard wording).

- [ ] **Step 5: Commit**

```
docs: document the failover profile hot-standby demo
```

---

## Verification (end-to-end)

1. `scripts/smoke.sh` — **27 passed, 0 failed**, clean teardown (the suite itself exercises stop → standby → restart → recovery).
2. Manual demo: the README "Failover demo" transcript verbatim.
3. Push; CI green (build step includes `--profile failover`; second run warm via `scope=node-backend`).
4. `grep -c '^LoadModule' reverse-proxy/httpd.conf` — still 17.

## Risks & Fallbacks

- **502 instead of standby takeover** — escalate; the hot-standby deferral on connection-refused is the feature under test. Do not add retries to checks.
- **Recovery slow in CI** — bounded by `--wait-timeout 60` plus the healthcheck interval (10 s); the check itself makes 6 requests, no retry loop beyond that.
- **balancer-manager string differs** — Task 1 verify has the documented fallback (`grep node-backend-standby`); record the actual string in the report, keep the check.
