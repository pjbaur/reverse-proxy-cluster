# Bybusyness Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `busy` Compose profile demonstrating `lbmethod=bybusyness`: two node members behind `balancer://busy` at `/busy/`, a `?delay=<ms>` parameter that holds a member busy, and a smoke contrast check proving the balancer skips the busy member where `byrequests` would not.

**Architecture:** Follows the established drop-in conventions exactly — server-level directives in a numbered `sites/` file, profile-gated compose services with explicit `hostname:` keys, config baked into the image (rebuild, never reload). One new httpd module (`mod_lbmethod_bybusyness`, 17 → 18). The node backend gains an additive query parameter; every existing profile and smoke expectation is untouched.

**Tech Stack:** Apache httpd 2.4 (`mod_proxy_balancer`, `mod_lbmethod_bybusyness`, `mod_slotmem_shm`), Docker Compose profiles, the existing zero-dependency node backend (`node:http`, no packages).

**Spec:** `docs/superpowers/specs/2026-08-29-bybusyness-demo-design.md` (approved).

## Global Constraints

- Apache 2.4-only syntax; server-level directives only (no new vhosts); the route must work identically on :8080 and the :443 vhost.
- `retry=0` on both `BalancerMember` lines, and **only** there — on a `balancer://` `ProxyPass`, `key=value` params are balancer params and httpd rejects worker params (same rule documented in `24-balanced.conf`).
- Healthchecks probe `127.0.0.1`, live in docker-compose.yml only. No published ports for backends.
- gha cache entries carry `scope=`; both busy services share the existing scope `node-backend`.
- Conventional commits; each task ends verified and committed; run the relevant smoke subset before committing.
- Module count goes **17 → 18**: exactly one new `LoadModule` (`lbmethod_bybusyness_module`), and the module-count references in `httpd.conf` (header comment), README, and CLAUDE.md all say 18.
- Service count goes 12 → 14. Full-suite smoke expectation after this feature: **37 passed, 0 failed**; `busy`-alone: **9** (4 proxy + 5 busy).
- Service names are load-bearing: `node-backend-busy-1` and `node-backend-busy-2` appear in `BalancerMember` URLs, in each service's `hostname:` key (the JSON `host` field is the container hostname), and in no smoke assertion (the contrast check is self-normalizing — it compares against the slow request's captured host, never a hardcoded member).
- The delay parameter is clamped 0–10000 ms; absent, non-numeric, or negative means 0. Never a timing assertion in smoke (CI-flaky); only body correctness and host distribution.
- `docs/REVIEW.md` is frozen — never edit it. `docs/BACKLOG.md` is updated by this feature (item 1 moves to Shipped).

---

## Task 1: `?delay=<ms>` in the node backend

**Files:**
- Modify: `backends/node/server.js`

**Interfaces:**
- Produces: `GET /messages?delay=<ms>` — identical JSON body to today, delivered after `ms` milliseconds (clamped 0–10000; bad values mean 0). Consumed by Task 2 (manual contrast) and Task 3 (smoke checks). No other route, header, or cookie behavior changes.

- [ ] **Step 1: Edit `backends/node/server.js`**

Two edits. First, extend the header comment (lines 1-2) — after the `nothing to install.` line add:

```js
// GET /messages accepts ?delay=<ms> (clamped 0-10000): the response is held
// for that many milliseconds so a balancer demo can keep one member busy.
```

Second, inside the request handler: add the delay parse after the `const path = ...` line (line 15), and wrap the `/messages` response in `setTimeout`. The handler becomes:

```js
const server = http.createServer((req, res) => {
  const path = req.url.split('?')[0];
  const params = new URL(req.url, 'http://localhost').searchParams;
  // absent / non-numeric / negative -> 0; capped at 10 s so a typo can't hang anything
  const delayMs = Math.min(Math.max(parseInt(params.get('delay'), 10) || 0, 0), 10000);

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
    setTimeout(() => {
      res.writeHead(200, headers);
      res.end(body);
    }, delayMs);
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'not found', path }));
});
```

Everything else in the file (PORT, ROUTE, listen) is unchanged.

- [ ] **Step 2: Verify the delay in isolation**

No test framework exists for the node backend (zero-dependency by design) — verify against a throw-away container:

```sh
docker build -q -t busy-node-test ./backends/node >/dev/null && echo BUILD-OK
docker run -d --rm --name busy-node-test -p 8081:8080 busy-node-test >/dev/null
sleep 1
time curl -fsS "http://127.0.0.1:8081/messages?delay=1000" >/dev/null   # real ~1.0s
curl -fsS "http://127.0.0.1:8081/messages" | grep -q '"backend":"node"' && echo PLAIN-OK
curl -fsS "http://127.0.0.1:8081/messages?delay=bogus" | grep -q '"backend":"node"' && echo BOGUS-OK
curl -fsS "http://127.0.0.1:8081/messages?delay=-5" | grep -q '"backend":"node"' && echo NEGATIVE-OK
docker rm -f busy-node-test >/dev/null
```

Expected: BUILD-OK, `?delay=1000` takes ~1.0 s real time, and the three instant responses all print their marker. `bogus`/`-5` returning immediately (treated as 0) is the clamping contract.

- [ ] **Step 3: Confirm no regression on the profiles that share this image**

```sh
scripts/smoke.sh node balanced     # 12 passed, 0 failed (4 proxy + 3 node + 5 balanced)
```

- [ ] **Step 4: Commit**

```
feat(node): optional ?delay=<ms> on /messages

Clamped 0-10000 ms, absent/non-numeric/negative means 0, identical JSON
body. Lets a load-balancer demo hold one member busy without new
dependencies; existing behavior untouched.
```

---

## Task 2: `busy` profile core (compose services + 27-busy.conf + module)

**Files:**
- Modify: `docker-compose.yml` (two services after `node-backend-sticky-2`, before the top-level `networks:` section at line 174)
- Create: `reverse-proxy/apacheconf/sites/27-busy.conf`
- Modify: `reverse-proxy/httpd.conf` (one `LoadModule`; header comment 17 → 18)

**Interfaces:**
- Consumes: `?delay=<ms>` from Task 1.
- Produces: profile `busy` with services `node-backend-busy-1`/`node-backend-busy-2` (DNS names on `proxy-net`, port 8080); route `GET /busy/messages` load-balanced by `bybusyness`. Consumed by Tasks 3 (smoke/CI) and 4 (docs).

- [ ] **Step 1: Append two services to `docker-compose.yml`**

After the `node-backend-sticky-2:` block (its `start_period: 5s` is the last line before the top-level `networks:`), append:

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

  node-backend-busy-2:
    build: ./backends/node
    hostname: node-backend-busy-2
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

Identical to the `node-backend-1` shape except service name, `hostname:`, and `profiles: ["busy"]`. No `ROUTE` env (no stickiness here).

- [ ] **Step 2: Add the module to `reverse-proxy/httpd.conf`**

In the load-balancing block (after the `lbmethod_byrequests_module` line, line 34) add:

```apache
LoadModule lbmethod_bybusyness_module modules/mod_lbmethod_bybusyness.so
```

Update the header comment (line 10): `# --- modules (17: proxy core+balancer, TLS pair, status, headers) -------` → `# --- modules (18: proxy core+balancer, TLS pair, status, headers) -------` (keep the trailing dashes' column alignment as-is; only 17 → 18).

- [ ] **Step 3: Create `reverse-proxy/apacheconf/sites/27-busy.conf`**

```apache
# /busy/... -> balancer://busy (two node members, Compose profile "busy").
# lbmethod=bybusyness elects the member with the fewest active requests, so
# a member holding a long request (/messages?delay=ms) is skipped until it
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

- [ ] **Step 4: Verify — including the live contrast**

```sh
docker compose --profile busy up -d --build --wait
docker compose ps    # 3 services: reverse-proxy + node-backend-busy-1/2, all (healthy)
docker compose exec reverse-proxy httpd -t        # Syntax OK
grep -c '^LoadModule' reverse-proxy/httpd.conf    # 18
curl -fsS http://localhost:8080/busy/messages | grep -q '"backend":"node"' && echo ROUTE-OK
curl -kfsS https://localhost:8443/busy/messages | grep -q '"backend":"node"' && echo TLS-OK
curl -fsS http://localhost:8080/balancer-manager | grep -q 'balancer://busy' && echo MANAGER-SHOWS-BUSY
   # (if this grep misses, grep for node-backend-busy-1 instead and record the
   #  actual dashboard string — do not delete the check)

# the contrast: hold one member busy for 3 s, then fire fast requests
curl -fsS "http://localhost:8080/busy/messages?delay=3000" -o /tmp/busy-slow.json &
sleep 0.3
for i in 1 2 3 4; do curl -fsS http://localhost:8080/busy/messages | grep -o '"host":"[^"]*"'; done
wait
grep -o '"host":"[^"]*"' /tmp/busy-slow.json && rm -f /tmp/busy-slow.json
docker compose --profile busy down --remove-orphans
```

Expected during the loop: **all four lines identical**, and the final slow-request line shows the *other* member — bybusyness skipped the busy one. Sanity contrast: the same transcript against `/balanced/messages` (byrequests) would alternate members across the four fast lines — that difference is the feature.

**Known risks:** If the four fast lines are *not* constant, `bybusyness` is not engaged — check `docker compose exec reverse-proxy httpd -M | grep bybusyness` shows the module, and that `ProxySet lbmethod=bybusyness` (not `byrequests`) is in `27-busy.conf`. If the fast lines are constant but *equal to* the slow host, the slow request was not in flight yet — do not shrink the 0.3 s settle; lengthen the `delay` instead. Node serves concurrently, so member 1 *could* answer fast requests — the assertion is about the balancer's routing choice, which is exactly what `bybusyness` exposes.

- [ ] **Step 5: Commit**

```
feat(proxy): busy profile demo with lbmethod=bybusyness

- node-backend-busy-1/2 under Compose profile "busy" (explicit hostname:
  so the JSON host names the member)
- sites/27-busy.conf: balancer://busy elects the member with the fewest
  active requests; a member holding a ?delay=ms request is skipped until
  it finishes, unlike byrequests round-robin
- httpd.conf: +lbmethod_bybusyness_module (17 -> 18 modules)
```

---

## Task 3: smoke + CI coverage

**Files:**
- Modify: `scripts/smoke.sh` (header comment, default profile list, new helper, `busy` case block)
- Modify: `.github/compose.cache.yml` (two services, shared scope)
- Modify: `.github/workflows/ci.yml` (build profile flag)

**Interfaces:**
- Consumes: route + services + delay from Tasks 1-2 (`/busy/messages`, `?delay=`, `node-backend-busy-1/2`, profile `busy`).
- Produces: full-suite expectation 37 passed / 0 failed; `smoke.sh busy` → 9.

- [ ] **Step 1: Edit `scripts/smoke.sh` defaults.** Header comment (line 4): `(default: all seven)` → `(default: all eight)`. Line 20:

```sh
  PROFILES="java nginx node python balanced failover sticky busy"
```

- [ ] **Step 2: Add the `check_avoids_busy` helper** — place directly after `check_host_constant` (after its closing `}` on line 121):

```sh
# check_avoids_busy <name> <url> — holds one ?delay=3000 request in flight
# against the url, then fetches 4 fast ones while it runs; every fast
# response's "host" must be identical and differ from the slow request's
# host (bybusyness skips the member with the active request; byrequests
# would alternate members, failing constancy).
check_avoids_busy() {
  name="$1"; url="$2"
  body_file="$(mktemp)"
  hosts=""
  curl -fsS "$url?delay=3000" -o "$body_file" 2>/dev/null &
  slow_pid=$!
  sleep 0.3
  i=0; empty=0
  while [ "$i" -lt 4 ]; do
    h="$(curl -fsS "$url" 2>/dev/null | sed -n 's/.*"host":"\([^"]*\)".*/\1/p')" || h=""
    if [ -n "$h" ]; then
      hosts="$hosts $h"
    else
      empty=$((empty + 1))
    fi
    i=$((i + 1))
  done
  wait "$slow_pid" 2>/dev/null || true
  slow_host="$(sed -n 's/.*"host":"\([^"]*\)".*/\1/p' "$body_file")"
  rm -f "$body_file"
  bad=0; first=""
  for h in $hosts; do
    if [ -z "$first" ]; then
      first="$h"
    elif [ "$h" != "$first" ]; then
      bad=$((bad + 1))
    fi
  done
  if [ "$first" = "$slow_host" ]; then
    bad=$((bad + 1))
  fi
  if [ "$bad" -eq 0 ] && [ "$empty" -eq 0 ] && [ -n "$first" ] && [ -n "$slow_host" ]; then
    ok "$name"
  else
    failed "$name - fast hosts '$hosts' not constant on the other member (slow: '$slow_host', empty: $empty) from $url"
  fi
}
```

Notes for the implementer: the script runs under `set -eu`, so the background curl is `wait`ed with `|| true` and every fetch's failure becomes an `empty` count, never a script abort. `mktemp` is drained by `rm -f` on both paths (the file is not needed by `cleanup()`). The slow host is read only after `wait` — the body does not exist until the delay elapses; that is why the fast hosts are collected first and compared after.

- [ ] **Step 3: Add the `busy` case block** — inside the profile loop, after the `sticky)` block (after its `;;`, before the `*)` arm):

```sh
    busy)
      check "busy: /busy/messages"                  "$BASE_HTTP/busy/messages"              '"backend":"node"'
      check "busy: X-Forwarded-Proto=http"          "$BASE_HTTP/busy/messages"              '"x_forwarded_proto":"http"'
      check "busy: /busy/messages over https"       "$BASE_HTTPS/busy/messages"             '"backend":"node"' -k
      check "busy: delay parameter honored"         "$BASE_HTTP/busy/messages?delay=500"    '"backend":"node"'
      check_avoids_busy "busy: bybusyness avoids the busy member" "$BASE_HTTP/busy/messages"
      ;;
```

No timing assertion on the `?delay=500` check — wall-clock asserts flake in CI; body correctness is the contract (Global Constraints).

- [ ] **Step 4: Extend `.github/compose.cache.yml`** — append after the `node-backend-sticky-2:` entry:

```yaml
  node-backend-busy-1:
    build:
      context: ./backends/node
      cache_from: ["type=gha,scope=node-backend"]
      cache_to: ["type=gha,mode=max,scope=node-backend"]
  node-backend-busy-2:
    build:
      context: ./backends/node
      cache_from: ["type=gha,scope=node-backend"]
      cache_to: ["type=gha,mode=max,scope=node-backend"]
```

- [ ] **Step 5: Edit `.github/workflows/ci.yml`** — the build step's profile list (line 26) gains `--profile busy`:

```yaml
            --profile java --profile nginx --profile node --profile python --profile balanced --profile failover --profile sticky --profile busy \
```

- [ ] **Step 6: Verify**

```sh
sh -n scripts/smoke.sh && echo SYNTAX-OK
docker compose -f docker-compose.yml -f .github/compose.cache.yml \
  --profile java --profile nginx --profile node --profile python --profile balanced --profile failover --profile sticky --profile busy config -q && echo MERGE-OK
scripts/smoke.sh busy    # 9 passed, 0 failed
scripts/smoke.sh         # 37 passed, 0 failed
```

- [ ] **Step 7: Commit**

```
test: smoke and CI coverage for the busy profile

- smoke.sh: busy case (route http+https, X-Forwarded-Proto, ?delay= body
  check, and the bybusyness contrast — four fast requests while a 3 s
  request is in flight must all land on the other member), default
  profiles now 8
- CI builds the busy profile; both services share gha cache scope
  node-backend
```

---

## Task 4: Docs (README, CLAUDE.md, landing page, backlog)

**Files:**
- Modify: `README.md`, `CLAUDE.md`, `reverse-proxy/apacheconf/htdocs/index.html`, `docs/BACKLOG.md`

**Interfaces:** Consumes Tasks 1-3 (route, services, 37-check suite, 18 modules, 14 services).

- [ ] **Step 1: README.md** — nine edits:

1. Intro (after the `sticky` sentence ending `...see [Sticky sessions demo](#sticky-sessions-demo).`, lines 13-14) add:

```markdown
An eighth profile, `busy`, routes by in-flight request count
(`lbmethod=bybusyness`) at `/busy/` — see [Busy demo](#busy-demo-bybusyness).
```

2. Architecture diagram: the `sticky` branch stops being the last (`└─▶`) entry — its connector becomes `├─▶` — and a new last branch is appended after it:

```
                              └─▶ /busy/    ─▶ balancer://busy     (profile busy)
                                                bybusyness (fewest active requests):
                                                ├─▶ node-backend-busy-1 :8080  ◀─ skipped while holding a ?delay=ms request
                                                └─▶ node-backend-busy-2 :8080
```

3. Service table: after the `node-backend-sticky-1, node-backend-sticky-2` row add:

```markdown
| node-backend-busy-1, node-backend-busy-2 | `node:22-alpine` (same build as `node-backend`) | `busy` | none | `/busy/` (via `balancer://busy`) |
```

4. Quickstart: "list all seven profiles" → "list all eight profiles"; the command gains `--profile busy`.

5. Routes table: after the `/sticky/messages` row add:

```markdown
| `GET /busy/messages[?delay=ms]` | `balancer://busy` | `busy` | JSON; while a `?delay=` request is in flight, every fast request lands on the *other* member |
```

6. New section between "Sticky sessions demo" and "Tests":

````markdown
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

# terminal 1 — hold one member busy for 3 s (note which host answers)
curl -s "http://localhost:8080/busy/messages?delay=3000" | grep -o '"host":"[^"]*"'

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
````

7. Tests section: `# all seven profiles — 32 checks` → `# all eight profiles — 37 checks`.

8. Configuration model list: after the `26-sticky.conf` bullet add:

```markdown
  - `27-busy.conf` — the bybusyness pair: `<Proxy "balancer://busy">` with
    two `BalancerMember` lines and `ProxySet lbmethod=bybusyness`, plus the
    `/busy/` `ProxyPass`/`ProxyPassReverse` pair. Same worker-parameters rule
    as 24: `retry=0` lives on the `BalancerMember` lines, not the balancer
    `ProxyPass`.
```

9. Healthchecks paragraph: extend the sentence naming the failover and sticky pairs to also name `the busy pair (`node-backend-busy-1`/`-2`)`. The proxy image bullet's `17 modules` → `18 modules`. If any sentence counts node services ("seven services sharing the single node image"), it becomes **nine** services.

- [ ] **Step 2: CLAUDE.md** — six edits:

1. Project profile table: add row after the `/sticky/` row:

```markdown
| `/busy/` | `balancer://busy` → node-backend-busy-1/2 | `busy` | 2× node: `lbmethod=bybusyness` |
```

2. Commands: the "every backend" example gains `--profile busy`; after the sticky line add:

```sh
docker compose --profile busy up -d --build       # bybusyness demo
```

3. Commands: `(32 checks)` → `(37 checks)`.

4. Structure, `docker-compose.yml` bullet: `all twelve services` → `all fourteen services` and the enumeration gains `the busy pair`.

5. Structure, `httpd.conf` bullet: `(17 modules)` → `(18 modules)`. Structure, `apacheconf/sites/` bullet: after the `26-sticky.conf` entry add `27-busy.conf` (`balancer://busy` with `lbmethod=bybusyness`).

6. Conventions, module bullet: `loads 17 modules by design` → `loads 18 modules by design`; extend the parenthetical to `...the balancer cost three: mod_slotmem_shm, mod_proxy_balancer, mod_lbmethod_byrequests; bybusyness a fourth: mod_lbmethod_bybusyness)`. Also extend the `backends/<name>/` contract bullet: `GET /messages returns JSON with ...` gains `, and (node) accepts ?delay=<ms> clamped 0–10000 to hold the response for a balancer demo`.

- [ ] **Step 3: Landing page** — `reverse-proxy/apacheconf/htdocs/index.html`, after the `/sticky/messages` `<li>`:

```html
    <li><code>GET /busy/messages?delay=ms</code> — bybusyness: the member with fewest active requests answers; a long request is skipped around (<code>--profile busy</code>)</li>
```

- [ ] **Step 4: `docs/BACKLOG.md`** — remove "### 1. `bybusyness` load-balancing contrast demo" from Open items; renumber the remaining open items 1–5. Under "Shipped from this backlog" add (top of that list):

```markdown
- **`bybusyness` contrast** — deferred 2026-08-25 in the balancer design,
  shipped 2026-08-29 as the `busy` profile (`27-busy.conf`,
  `node-backend-busy-1/2`, `?delay=` in the node backend).
```

- [ ] **Step 5: Verify**

```sh
docker compose --profile busy up -d --build --wait    # rebuild picks up the landing page
curl -fsS http://localhost:8080/ | grep -q 'busy' && echo LANDING-OK
grep -c '^LoadModule' reverse-proxy/httpd.conf        # 18
grep -rn '32 checks\|all seven\|17 modules\|twelve services' README.md CLAUDE.md scripts/smoke.sh   # no hits
scripts/smoke.sh busy                                 # 9 passed, 0 failed
docker compose --profile busy down --remove-orphans
```

Then spot-check every documented claim against the files (service names, route, delay clamp, dashboard wording).

- [ ] **Step 6: Commit**

```
docs: document the busy profile bybusyness demo
```

---

## Verification (end-to-end)

1. `scripts/smoke.sh` — **37 passed, 0 failed**, clean teardown (includes the live contrast check).
2. Manual demo: the README "Busy demo (bybusyness)" two-terminal transcript verbatim.
3. Push; CI green (build step includes `--profile busy`; second run warm via `scope=node-backend`).
4. `grep -c '^LoadModule' reverse-proxy/httpd.conf` — 18.
5. `docs/BACKLOG.md` shows bybusyness under Shipped, five open items remain.

## Risks & Fallbacks

- **Fast hosts not constant in the contrast check** — `bybusyness` not engaged: confirm the module (`httpd -M | grep bybusyness`) and `ProxySet lbmethod=bybusyness`. Escalate rather than retry-loop; the routing decision is the feature under test.
- **Fast lines constant but equal to the slow host** — slow request not yet dispatched when the fast ones ran: lengthen the delay (never shorten the 0.3 s settle), or confirm the `?delay=` parameter reached the backend (`curl .../busy/messages?delay=2000` visibly hangs).
- **CI runner slowness** — the 4 fast fetches (~tens of ms) sit inside a 3 s window; if ever raced, raise the delay.
- **balancer-manager string differs** — Task 2 verify has the documented fallback (`grep node-backend-busy-1`); record the actual string in the report, keep the check.
