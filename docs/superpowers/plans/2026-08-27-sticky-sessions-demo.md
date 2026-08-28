# Sticky Sessions Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `sticky` Compose profile demonstrating Apache session affinity: two node members behind `balancer://sticky` at `/sticky/`, where a client holding a `SESSIONID` cookie (route baked into its value, jvmRoute-style) is pinned to one member while cookie-less clients still get round-robin.

**Architecture:** Follows the established drop-in conventions exactly — server-level directives in a numbered `sites/` file, profile-gated compose services with explicit `hostname:` keys, config baked into the image. The one backend change is `ROUTE`-gated: the node app mints `Set-Cookie: SESSIONID=<uuid>.<ROUTE>` only when the env var is present, so every other profile is untouched. No new httpd modules.

**Tech Stack:** Apache httpd 2.4 (`mod_proxy_balancer`, `mod_lbmethod_byrequests`, `mod_slotmem_shm` — all already loaded), Docker Compose profiles, the existing node backend image plus a small `server.js` change, curl cookie jars for verification.

**Spec:** `docs/superpowers/specs/2026-08-27-sticky-sessions-design.md` (approved).

## Global Constraints

- Apache 2.4-only syntax; server-level directives only (no new vhosts); `retry=0` on every worker (nothing in this feature depends on error state).
- **The route string is load-bearing and appears in four places that must stay identical:** the service name (`node-backend-sticky-1`), the service's `hostname:` key, the service's `ROUTE` env var, and the `BalancerMember ... route=` param (likewise `-2`). Apache routes by the cookie's `.`-suffix; if any pair drifts, stickiness silently degrades to round-robin — no error, just wrong behaviour. Never rename one without the others.
- Cookie name `SESSIONID` must match between the backend (`Set-Cookie: SESSIONID=...`) and the balancer (`ProxySet stickysession=SESSIONID`) — same silent-degradation risk.
- Healthchecks probe `127.0.0.1`, live in docker-compose.yml only.
- No published ports for backends; everything reachable via the proxy (8080/8443).
- gha cache entries carry `scope=`; both sticky services share the existing scope `node-backend`.
- Conventional commits; each task ends verified and committed; run the relevant smoke subset before committing.
- Module count stays **17** (no `httpd.conf` changes in this feature).
- The node backend stays zero-dependency: `crypto.randomUUID()` is a builtin (Node ≥ 14.17; the image is `node:22-alpine`).
- Full-suite smoke expectation after this feature: **32 passed, 0 failed**; `sticky`-alone: **9** (4 proxy + 5 sticky).

---

## Task 1: Sticky core (backend cookie + compose services + 26-sticky.conf)

**Files:**
- Modify: `backends/node/server.js` (requires + the `/messages` handler)
- Modify: `docker-compose.yml` (append two services after `node-backend-standby`, before `networks:`)
- Create: `reverse-proxy/apacheconf/sites/26-sticky.conf`

**Interfaces:**
- Produces: profile `sticky` with services `node-backend-sticky-1` and `node-backend-sticky-2` (DNS names on `proxy-net`, port 8080, each exporting `ROUTE=<its own name>`); route `GET /sticky/messages` → `{"backend":"node",...}` where a cookie-jar client always sees the same `"host"` and a cookie-less client sees both hosts alternating. Consumed by Tasks 2 (smoke/CI) and 3 (docs).
- Also produces: `backends/node/server.js` sets `Set-Cookie: SESSIONID=<uuid>.<ROUTE>; Path=/` on `GET /messages` **iff** the `ROUTE` env var is set — all existing profiles set no `ROUTE`, so their responses change not at all.

- [ ] **Step 1: Edit `backends/node/server.js`**

Replace the top requires and constant (lines 5-8):

```js
const http = require('node:http');
const os = require('node:os');

const PORT = 8080;
```

with:

```js
const http = require('node:http');
const os = require('node:os');
const crypto = require('node:crypto');

const PORT = 8080;
// ROUTE, when set (sticky profile), is baked into the session cookie so the
// proxy balancer can pin the client to this member (jvmRoute-style).
const route = process.env.ROUTE || null;
```

Then replace the `/messages` handler block (lines 13-23):

```js
  if (req.method === 'GET' && path === '/messages') {
    const body = JSON.stringify({
      backend: 'node',
      message: 'Hello from Node.js',
      host: os.hostname(),
      x_forwarded_proto: req.headers['x-forwarded-proto'] || null,
      x_forwarded_port: req.headers['x-forwarded-port'] || null,
      x_forwarded_for: req.headers['x-forwarded-for'] || null,
    });
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(body);
    return;
  }
```

with:

```js
  if (req.method === 'GET' && path === '/messages') {
    const headers = { 'Content-Type': 'application/json' };
    if (route) {
      headers['Set-Cookie'] = `SESSIONID=${crypto.randomUUID()}.${route}; Path=/`;
    }
    const body = JSON.stringify({
      backend: 'node',
      message: 'Hello from Node.js',
      host: os.hostname(),
      x_forwarded_proto: req.headers['x-forwarded-proto'] || null,
      x_forwarded_port: req.headers['x-forwarded-port'] || null,
      x_forwarded_for: req.headers['x-forwarded-for'] || null,
    });
    res.writeHead(200, headers);
    res.end(body);
    return;
  }
```

(`Path=/` because the backend serves `/messages` while the client visits `/sticky/messages`. The cookie is re-minted per response — the uuid changes but the route suffix never does, so affinity holds and the handler stays stateless. The JSON body is deliberately unchanged.)

- [ ] **Step 2: Append two services to `docker-compose.yml`**

After the `node-backend-standby:` block (ends line 140, before `networks:`), append:

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

  node-backend-sticky-2:
    build: ./backends/node
    hostname: node-backend-sticky-2
    profiles: ["sticky"]
    environment:
      ROUTE: node-backend-sticky-2
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

Identical to the failover pair's shape plus the `environment: ROUTE:` block. The `ROUTE` value must equal the service name and `hostname:` exactly (Global Constraints).

- [ ] **Step 3: Create `reverse-proxy/apacheconf/sites/26-sticky.conf`**

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

- [ ] **Step 4: Verify — including live pinning and the no-cookie regression**

```sh
docker compose --profile sticky up -d --build --wait
docker compose ps    # 3 services: reverse-proxy + sticky-1 + sticky-2, all (healthy)
docker compose exec reverse-proxy httpd -t        # Syntax OK

# a) cookie-less client: alternates between the two members
for i in 1 2 3 4 5 6; do curl -fsS http://localhost:8080/sticky/messages | grep -o '"host":"[^"]*"'; done
   # both node-backend-sticky-1 and -2 appear (alternation)

# b) the response sets the route cookie
curl -isS http://localhost:8080/sticky/messages | grep -i '^set-cookie:'
   # Set-Cookie: SESSIONID=<uuid>.node-backend-sticky-1   (or -2; matches the host above)

# c) cookie-jar client: pinned
rm -f /tmp/sticky-jar
for i in 1 2 3 4 5 6; do curl -fsS -b /tmp/sticky-jar -c /tmp/sticky-jar http://localhost:8080/sticky/messages | grep -o '"host":"[^"]*"'; done
   # six identical lines
grep -o 'node-backend-sticky-[12]' /tmp/sticky-jar | sort -u    # exactly one

# d) a second jar pins independently
rm -f /tmp/sticky-jar-b
for i in 1 2 3 4 5 6; do curl -fsS -b /tmp/sticky-jar-b -c /tmp/sticky-jar-b http://localhost:8080/sticky/messages | grep -o '"host":"[^"]*"'; done
   # six identical lines (either member — constancy is the assertion, not identity)
rm -f /tmp/sticky-jar /tmp/sticky-jar-b

curl -kfsS https://localhost:8443/sticky/messages | grep -q '"backend":"node"' && echo TLS-OK
curl -fsS http://localhost:8080/balancer-manager | grep -q 'balancer://sticky' && echo MANAGER-SHOWS-STICKY
   # (if this grep misses, grep for node-backend-sticky-1 instead and record
   #  the actual dashboard string — do not delete the check)

# e) regression: profiles without ROUTE set no cookie
docker compose --profile node up -d --wait
curl -isS http://localhost:8080/node/messages | grep -c -i '^set-cookie:'
   # 0
docker compose --profile node --profile sticky down --remove-orphans
```

**Known risks:** If step (c) shows both hosts, stickiness is silently off — check the cookie name (`SESSIONID` in both `server.js` and `stickysession=`), the `.`-suffix, and the route/ROUTE/service-name triple before touching anything else (Global Constraints). If step (e) prints anything but `0`, the cookie leaked into the plain node profile — the `if (route)` gate is missing or wrong.

- [ ] **Step 5: Commit**

```
feat(proxy): sticky profile demo with session affinity

- node-backend-sticky-1 + node-backend-sticky-2 under Compose profile
  "sticky", each exporting ROUTE=<its own name>
- backends/node: ROUTE-gated Set-Cookie SESSIONID=<uuid>.<ROUTE>
  (jvmRoute-style; other profiles set no ROUTE and see no cookie)
- sites/26-sticky.conf: balancer://sticky with per-member route= and
  ProxySet stickysession=SESSIONID; no new modules (still 17)
```

---

## Task 2: smoke + CI coverage

**Files:**
- Modify: `scripts/smoke.sh` (header comment, default profile list, jar tempdir + cleanup, new helper, `sticky` case block)
- Modify: `.github/compose.cache.yml` (two services, shared scope)
- Modify: `.github/workflows/ci.yml` (build profile flag)

**Interfaces:**
- Consumes: route + services from Task 1 (`/sticky/messages`, `node-backend-sticky-1/2`, profile `sticky`).
- Produces: full-suite expectation 32 passed / 0 failed; `smoke.sh sticky` → 9.

- [ ] **Step 1: Edit `scripts/smoke.sh` defaults.** Line 4 comment: `(default: all six)` → `(default: all seven)`. Line 20:

```sh
  PROFILES="java nginx node python balanced failover sticky"
```

- [ ] **Step 2: Jar tempdir + cleanup.** The `cleanup()` function (line 97) gains a jar-directory remove. Replace:

```sh
cleanup() {
  note "tearing down"
  # shellcheck disable=SC2086
  docker compose $PROFILE_ARGS down --remove-orphans --timeout 5 >/dev/null 2>&1 || true
}
```

with:

```sh
cleanup() {
  note "tearing down"
  # shellcheck disable=SC2086
  docker compose $PROFILE_ARGS down --remove-orphans --timeout 5 >/dev/null 2>&1 || true
  [ -n "${STICKY_DIR:-}" ] && rm -rf "$STICKY_DIR"
}
```

(The `${STICKY_DIR:-}` guard matters: the script runs under `set -eu` and the EXIT trap fires even if the run dies before the variable is set.)

Then after the `up -d --build --wait` line (line 112), next to the `BASE_HTTP`/`BASE_HTTPS` definitions (lines 114-115), add:

```sh
STICKY_DIR="$(mktemp -d)"   # cookie jars for the sticky pinning checks
```

- [ ] **Step 3: Add the `check_host_constant` helper** — place directly after `check_host_exact` (after its closing `}` on line 95):

```sh
# check_host_constant <name> <url> <jar> — fetches 6 times through a curl
# cookie jar; every response's "host" must be the same value (stickiness
# pins a client to one member; which member is not deterministic under
# byrequests, so constancy is the assertion, not identity).
check_host_constant() {
  name="$1"; url="$2"; jar="$3"
  first=""
  i=0; bad=0; empty=0
  while [ "$i" -lt 6 ]; do
    h="$(curl -fsS -b "$jar" -c "$jar" "$url" 2>/dev/null | sed -n 's/.*"host":"\([^"]*\)".*/\1/p')" || h=""
    if [ -z "$h" ]; then
      empty=$((empty + 1))
    elif [ -z "$first" ]; then
      first="$h"
    elif [ "$h" != "$first" ]; then
      bad=$((bad + 1))
    fi
    i=$((i + 1))
  done
  if [ "$bad" -eq 0 ] && [ "$empty" -eq 0 ]; then
    ok "$name"
  else
    failed "$name - $bad drifted, $empty failed responses (wanted one constant host) from $url"
  fi
}
```

- [ ] **Step 4: Add the `sticky` case block** — inside the profile loop, after the `failover)` block (after its `;;`):

```sh
    sticky)
      check "sticky: /sticky/messages"                "$BASE_HTTP/sticky/messages"    '"backend":"node"'
      check "sticky: /sticky/messages over https"     "$BASE_HTTPS/sticky/messages"   '"backend":"node"' -k
      check_rotates       "sticky: rotation without cookie" "$BASE_HTTP/sticky/messages" 2
      check_host_constant "sticky: jar A pinned"      "$BASE_HTTP/sticky/messages"    "$STICKY_DIR/a.jar"
      check_host_constant "sticky: jar B pinned"      "$BASE_HTTP/sticky/messages"    "$STICKY_DIR/b.jar"
      ;;
```

Notes for the implementer: two separate jars (not one) are the point of check 5 — each client must pin independently, proving per-client affinity rather than a global pin. `check_rotates` reuses the balanced helper unchanged; with no cookie the balancer must still alternate (12 fetches, ≥ 2 distinct hosts over 2 members).

- [ ] **Step 5: Extend `.github/compose.cache.yml`** — append after the `node-backend-standby:` entry:

```yaml
  node-backend-sticky-1:
    build:
      context: ./backends/node
      cache_from: ["type=gha,scope=node-backend"]
      cache_to: ["type=gha,mode=max,scope=node-backend"]
  node-backend-sticky-2:
    build:
      context: ./backends/node
      cache_from: ["type=gha,scope=node-backend"]
      cache_to: ["type=gha,mode=max,scope=node-backend"]
```

- [ ] **Step 6: Edit `.github/workflows/ci.yml`** — the build step's profile list (line 26) gains `--profile sticky`:

```yaml
            --profile java --profile nginx --profile node --profile python --profile balanced --profile failover --profile sticky \
```

- [ ] **Step 7: Verify**

```sh
sh -n scripts/smoke.sh && echo SYNTAX-OK
docker compose -f docker-compose.yml -f .github/compose.cache.yml \
  --profile java --profile nginx --profile node --profile python --profile balanced --profile failover --profile sticky config -q && echo MERGE-OK
scripts/smoke.sh sticky    # 9 passed, 0 failed
scripts/smoke.sh           # 32 passed, 0 failed
```

- [ ] **Step 8: Commit**

```
test: smoke and CI coverage for the sticky profile

- smoke.sh: sticky case (route http+https, rotation without cookie,
  two cookie jars each pinned to a constant member), default profiles
  now 7; jar tempdir removed in the cleanup trap
- CI builds the sticky profile; both services share gha cache scope
  node-backend
```

---

## Task 3: Docs (README, CLAUDE.md, landing page)

**Files:**
- Modify: `README.md`, `CLAUDE.md`, `reverse-proxy/apacheconf/htdocs/index.html`

**Interfaces:** Consumes Tasks 1-2 (route, services, 32-check suite).

- [ ] **Step 1: README.md** — ten edits:

1. Intro (lines 8-12): after the failover sentence (`— see [Failover demo](#failover-demo).`) add:

```markdown
A seventh profile, `sticky`, pins each client to one member via a session
cookie at `/sticky/` — see [Sticky sessions demo](#sticky-sessions-demo).
```

2. Architecture diagram: the `failover` branch stops being the last (`└─▶`) entry. Restructure lines 31-34 to:

```
                              ├─▶ /failover/ ─▶ balancer://failover (profile failover)
                              │                 hot standby (status=+H):
                              │                 ├─▶ node-backend-primary :8080  ◀─ serves all
                              │                 └─▶ node-backend-standby :8080  ◀─ on error only
                              └─▶ /sticky/  ─▶ balancer://sticky  (profile sticky)
                                                session affinity (stickysession=SESSIONID):
                                                ├─▶ node-backend-sticky-1 :8080  ◀─ cookie suffix .node-backend-sticky-1
                                                └─▶ node-backend-sticky-2 :8080  ◀─ cookie suffix .node-backend-sticky-2
```

3. Service table: after the `node-backend-primary, node-backend-standby` row add:

```markdown
| node-backend-sticky-1, node-backend-sticky-2 | `node:22-alpine` (same build as `node-backend`) | `sticky` | none | `/sticky/` (via `balancer://sticky`) |
```

4. Quickstart (line 68): "list all six profiles" → "list all seven profiles"; the command (line 71) gains `--profile sticky`.

5. Routes table: after the `/failover/messages` row add:

```markdown
| `GET /sticky/messages` | `balancer://sticky` | `sticky` | JSON; `host` is constant per client cookie, alternating without one |
```

6. New section between "Failover demo" and "Tests":

````markdown
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
`/balancer-manager` lists the `sticky` balancer with each member's route
in its URL column.

If the cookie name, the `.` suffix, or the route/`ROUTE`/service-name
triple ever drifts, stickiness degrades silently to round-robin — no
error, just rotation. The smoke suite's pinning checks are the guard.
````

7. Tests section (line 197): `# all six profiles — 27 checks` → `# all seven profiles — 32 checks`.

8. CI paragraph (lines 206-208): "build five distinct images — the `balanced` replicas and the `failover` pair are five services sharing the single node image" → "build five distinct images — the `balanced` replicas, the `failover` pair and the `sticky` pair are seven services sharing the single node image".

9. Configuration model list: after the `25-failover.conf` bullet add:

```markdown
  - `26-sticky.conf` — session affinity: `<Proxy "balancer://sticky">` with
    two `BalancerMember` lines carrying `route=node-backend-sticky-1/2`
    (each matching that service's `ROUTE` env var and `hostname:`), plus
    `ProxySet stickysession=SESSIONID` — the balancer routes by the
    `.`-suffix of the client's `SESSIONID` cookie. Same worker-parameters
    rule as 24: worker parameters live on the `BalancerMember` lines, not
    the balancer `ProxyPass`.
```

10. Healthchecks paragraph (lines 261-263): extend `and the failover pair (`node-backend-primary`/`node-backend-standby`)` to also name `and the sticky pair (`node-backend-sticky-1`/`-2`)`.

- [ ] **Step 2: CLAUDE.md** — five edits:

1. Project profile table: add row after the `/failover/` row:

```markdown
| `/sticky/` | `balancer://sticky` → node-backend-sticky-1/2 | `sticky` | 2× node: session affinity (`stickysession`) |
```

2. Commands: the "every backend" example gains `--profile sticky`; after the failover line add:

```sh
docker compose --profile sticky up -d --build    # session-affinity (sticky) demo
```

3. Commands: the smoke-suite comment `(27 checks)` → `(32 checks)`.

4. Structure: extend the `apacheconf/sites/` bullet — after the `25-failover.conf (...)` text add:

```markdown
  `26-sticky.conf` (`balancer://sticky` session affinity:
  `node-backend-sticky-1/2` with `route=` + `stickysession=SESSIONID`)
```

5. Conventions: add bullet after the "Hot standby needs..." bullet:

```markdown
- **Sticky routes need the route string in four places.** The member's
  `route=` param, the service's `ROUTE` env var (the node app bakes it
  into the `SESSIONID` cookie suffix, jvmRoute-style), the service name,
  and its `hostname:` key must all be identical, and the cookie name must
  match `stickysession=`. Any drift degrades stickiness silently to
  round-robin — no error, just rotation; the smoke pinning checks are the
  only guard.
```

- [ ] **Step 3: Landing page** — `reverse-proxy/apacheconf/htdocs/index.html`, after the `/failover/messages` `<li>`:

```html
    <li><code>GET /sticky/messages</code> — session affinity: one member per client cookie, round-robin without (<code>--profile sticky</code>)</li>
```

- [ ] **Step 4: Verify**

```sh
docker compose --profile sticky up -d --build --wait    # rebuild picks up the landing page
curl -fsS http://localhost:8080/ | grep -q sticky && echo LANDING-OK
grep -c '^LoadModule' reverse-proxy/httpd.conf            # 17
grep -rn '27 checks\|all six' README.md CLAUDE.md scripts/smoke.sh   # no hits
scripts/smoke.sh sticky                                   # 9 passed, 0 failed
docker compose --profile sticky down --remove-orphans
```

Then spot-check every documented claim against the files (service names, route, cookie name, dashboard wording).

- [ ] **Step 5: Commit**

```
docs: document the sticky profile session-affinity demo
```

---

## Verification (end-to-end)

1. `scripts/smoke.sh` — **32 passed, 0 failed**, clean teardown.
2. Manual demo: the README "Sticky sessions demo" transcript verbatim (no-jar alternation, pinned jar, cookie inspection, second jar).
3. Push; CI green (build step includes `--profile sticky`; second run warm via `scope=node-backend`).
4. `grep -c '^LoadModule' reverse-proxy/httpd.conf` — still 17.

## Risks & Fallbacks

- **Silent degradation to round-robin** — wrong cookie name, missing `.`-suffix, or a route/ROUTE/name mismatch produces no error; the jar checks are the only guard. Diagnose with `curl -v` showing the actual `Set-Cookie` value before touching the balancer.
- **check_rotates flake** — 12 cookie-less fetches over 2 members must hit both; under byrequests alternation this is deterministic in practice (same confidence as the existing 3-member balanced check).
- **balancer-manager string differs** — Task 1 verify has the documented fallback (`grep node-backend-sticky-1`); record the actual string in the report, keep the check.
