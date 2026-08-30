# Sticky Failover Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `stickyfailover` Compose profile answering backlog item 1: two balancers over one sticky primary/`status=+H`-standby pair — the default one moves a pinned session to the standby on failure (and never back), the `nofailover=On` one breaks it with 503 instead (and it resumes on the primary after recovery).

**Architecture:** Follows the established drop-in conventions exactly — server-level directives in a numbered `sites/` file, profile-gated compose services with explicit `hostname:` and `ROUTE` env keys, config baked into the image (rebuild, never reload). Two `<Proxy balancer://...>` blocks share the same two services; error state is tracked per balancer, so the smoke outage warms each balancer with its own pinned client. No new httpd modules. Every existing profile and smoke expectation is untouched.

**Tech Stack:** Apache httpd 2.4 (`mod_proxy_balancer`, `stickysession`, `nofailover`, `status=+H`), Docker Compose profiles, the existing zero-dependency node backend (`node:http`, no changes to it in this feature).

**Spec:** `docs/superpowers/specs/2026-08-30-sticky-failover-design.md` (approved).

## Global Constraints

- Apache 2.4-only syntax; server-level directives only (no vhost edits); both routes must work identically on :8080 and the inherited :443 vhost.
- Worker parameters (`route=`, `retry=`, `status=`) live **only** on `BalancerMember` lines — on a `balancer://` `ProxyPass`, `key=value` params are balancer params and httpd rejects worker params there (rule documented in `24-balanced.conf`). `stickysession`/`nofailover`/`lbmethod` are balancer params and live in `ProxySet`.
- `retry=5` on both primaries, `retry=0` on both standbys — identical to `25-failover.conf`. `retry=0` on the primary would wipe the worker error state and break hot standby.
- Four-places rule: each member's `route=` string, the service's `ROUTE` env var, the Compose service name, and its `hostname:` key are the identical string `node-backend-sf-primary` / `node-backend-sf-standby`. Cookie name is `SESSIONID` (matches `stickysession=` and the node backend's `Set-Cookie`).
- Healthchecks probe `127.0.0.1`, live in `docker-compose.yml` only. No published ports for backends.
- Module count stays **18** — no `httpd.conf` change.
- Service count goes 14 → 16. Full-suite smoke expectation after this feature: **51 passed, 0 failed**; `stickyfailover`-alone: **18** (4 proxy + 14 case checks).
- gha cache entries carry `scope=`; both new services share the existing scope `node-backend`.
- Conventional commits; each task ends verified and committed; run `scripts/smoke.sh stickyfailover` (or the full suite where stated) before committing.
- Never a timing assertion in smoke. The two recovery landing-spot checks are deterministic (the cookie's route decides, not scheduling); the `--wait` healthcheck interval (10 s) outlasts the primary's 5 s retry window, the same timing argument the `failover` case already relies on.
- `docs/REVIEW.md` is frozen — never edit it. `docs/BACKLOG.md` is updated by this feature (item 1 moves to Shipped, remaining items renumber).
- Do not commit generated files: `reverse-proxy/certs/` is gitignored; cookie jars live in a `mktemp -d` dir removed by the smoke cleanup trap.

---

## Task 1: Compose services, site config, steady-state smoke

**Files:**
- Modify: `docker-compose.yml` (insert two services after `node-backend-busy-2`, before `networks:`)
- Create: `reverse-proxy/apacheconf/sites/28-stickyfailover.conf`
- Modify: `scripts/smoke.sh` (default `PROFILES` list; new `stickyfailover)` case with steady-state checks)

**Interfaces:**
- Produces: services `node-backend-sf-primary` / `node-backend-sf-standby` (port 8080, cookie `SESSIONID=<uuid>.<service-name>`); routes `GET /stickyfailover/messages` and `GET /stickyfailover-strict/messages` returning the standard node JSON (`backend`, `message`, `host`, `x_forwarded_*`). Consumed by Tasks 2–3 (smoke) and Task 5 (docs).

- [ ] **Step 1: Add the two Compose services**

In `docker-compose.yml`, after the `node-backend-busy-2:` block (its `start_period: 5s` line) and before the top-level `networks:` key, insert (two-space indent, matching the file):

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
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/messages"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s
```

- [ ] **Step 2: Create `reverse-proxy/apacheconf/sites/28-stickyfailover.conf`**

Entire file:

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

- [ ] **Step 3: Extend the smoke default profile list**

In `scripts/smoke.sh` line 20, change:

```sh
  PROFILES="java nginx node python balanced failover sticky busy"
```

to:

```sh
  PROFILES="java nginx node python balanced failover sticky busy stickyfailover"
```

- [ ] **Step 4: Add the steady-state smoke case**

In `scripts/smoke.sh`, after the `busy)` case block (after its `check_avoids_busy` line and `;;`), add:

```sh
    stickyfailover)
      check "stickyfailover: /stickyfailover/messages"               "$BASE_HTTP/stickyfailover/messages"              '"backend":"node"'
      check "stickyfailover: X-Forwarded-Proto=http"                 "$BASE_HTTP/stickyfailover/messages"              '"x_forwarded_proto":"http"'
      check "stickyfailover: /stickyfailover/messages over https"    "$BASE_HTTPS/stickyfailover/messages"             '"backend":"node"' -k
      check_host_exact "stickyfailover: unpinned always primary"     "$BASE_HTTP/stickyfailover/messages"              node-backend-sf-primary
      check "stickyfailover: strict /stickyfailover-strict/messages" "$BASE_HTTP/stickyfailover-strict/messages"       '"backend":"node"'
      ;;
```

- [ ] **Step 5: Run the smoke suite for this profile**

Run: `scripts/smoke.sh stickyfailover`
Expected: `summary: 9 passed, 0 failed` (4 proxy checks + 5 case checks). If the proxy fails to start, check `docker compose logs reverse-proxy` for an httpd syntax error in `28-stickyfailover.conf` (most likely cause: a worker param outside a `BalancerMember` line).

- [ ] **Step 6: Commit**

```bash
git add docker-compose.yml reverse-proxy/apacheconf/sites/28-stickyfailover.conf scripts/smoke.sh
git commit -m "feat(proxy): stickyfailover profile with sticky hot-standby pair"
```

---

## Task 2: Pin both jars before any failure

**Files:**
- Modify: `scripts/smoke.sh` (new helper `check_host_exact_jar` after `check_host_constant`; two pin checks in the `stickyfailover` case)

**Interfaces:**
- Consumes: routes from Task 1.
- Produces: `check_host_exact_jar <name> <url> <jar> <expected-host>` — six fetches through a curl cookie jar (`-b`/`-c`), every response's `host` field must equal `expected-host`; counts wrong/empty separately like `check_host_exact`. Consumed by Task 3 for the outage and recovery assertions.

- [ ] **Step 1: Add the helper**

In `scripts/smoke.sh`, after the `check_host_constant` function (after its closing `}`) and before the `check_avoids_busy` comment block, insert:

```sh
# check_host_exact_jar <name> <url> <jar> <expected-host> — fetches 6 times
# through a curl cookie jar; every response's "host" must equal
# expected-host. Where a jar-carrying client lands is deterministic (the
# cookie's route decides), unlike plain byrequests rotation.
check_host_exact_jar() {
  name="$1"; url="$2"; jar="$3"; want="$4"
  i=0; bad=0; empty=0
  while [ "$i" -lt 6 ]; do
    h="$(curl -fsS -b "$jar" -c "$jar" "$url" 2>/dev/null | sed -n 's/.*"host":"\([^"]*\)".*/\1/p')" || h=""
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

- [ ] **Step 2: Add the pin checks**

In the `stickyfailover)` case, after the strict `/stickyfailover-strict/messages` check and before the `;;`, add:

```sh
      check_host_exact_jar "stickyfailover: jar A pinned to primary"       "$BASE_HTTP/stickyfailover/messages"        "$STICKY_DIR/sfa.jar" node-backend-sf-primary
      check_host_exact_jar "stickyfailover: jar B pinned to primary"       "$BASE_HTTP/stickyfailover-strict/messages" "$STICKY_DIR/sfb.jar" node-backend-sf-primary
```

(`STICKY_DIR` is the existing `mktemp -d` jar directory; the cleanup trap already removes it. Nothing new to clean up.)

- [ ] **Step 3: Run the smoke suite for this profile**

Run: `scripts/smoke.sh stickyfailover`
Expected: `summary: 11 passed, 0 failed`.

- [ ] **Step 4: Commit**

```bash
git add scripts/smoke.sh
git commit -m "test(smoke): pin two stickyfailover jars before the outage"
```

---

## Task 3: Outage and recovery choreography

**Files:**
- Modify: `scripts/smoke.sh` (outage + recovery block in the `stickyfailover` case, after the pin checks, before the `;;`)

**Interfaces:**
- Consumes: `check_host_exact_jar` and jars `"$STICKY_DIR/sfa.jar"` / `"$STICKY_DIR/sfb.jar"` from Task 2; `check_status` (existing — extra curl args go after `url` and are placed before the URL on the curl command line).

- [ ] **Step 1: Add the outage + recovery block**

In the `stickyfailover)` case, after the jar B pin check and before the `;;`, add:

```sh
      # shellcheck disable=SC2086
      if docker compose $PROFILE_ARGS stop node-backend-sf-primary >/dev/null 2>&1; then
        # Warm both balancers through their transition request with the
        # pinned clients. The first request after the stop is the transition
        # itself and is nondeterministic (DNS lookup failure -> 500, or a
        # block on the dead address until the ~60 s Timeout) — discard it.
        # The pinned warm request is also what puts each balancer's PRIMARY
        # worker into error state: the two balancers track error state
        # independently, and a cookie-less warm request would be elected
        # straight to the standby without ever touching the dead primary —
        # on the strict balancer that would not create the 503 condition.
        curl -fsS --max-time 70 -b "$STICKY_DIR/sfa.jar" -c "$STICKY_DIR/sfa.jar" \
          "$BASE_HTTP/stickyfailover/messages" >/dev/null 2>&1 || true
        curl -fsS --max-time 70 -b "$STICKY_DIR/sfb.jar" -c "$STICKY_DIR/sfb.jar" \
          "$BASE_HTTP/stickyfailover-strict/messages" >/dev/null 2>&1 || true
        check_host_exact_jar "stickyfailover: pinned session moved to standby" \
          "$BASE_HTTP/stickyfailover/messages" "$STICKY_DIR/sfa.jar" node-backend-sf-standby
        check_host_exact "stickyfailover: cookie-less served by standby" \
          "$BASE_HTTP/stickyfailover/messages" node-backend-sf-standby
        check_status "stickyfailover: strict pinned session breaks (503)" 503 \
          "$BASE_HTTP/stickyfailover-strict/messages" -b "$STICKY_DIR/sfb.jar" -c "$STICKY_DIR/sfb.jar"
        check_host_exact "stickyfailover: strict cookie-less still served" \
          "$BASE_HTTP/stickyfailover-strict/messages" node-backend-sf-standby
        # shellcheck disable=SC2086
        if docker compose $PROFILE_ARGS up -d --wait --wait-timeout 60 node-backend-sf-primary >/dev/null 2>&1; then
          # --wait outlasts the primary's 5 s retry window (the healthcheck
          # interval alone is 10 s), so the primary worker is usable again.
          # The landing spots are still decided by the cookies: jar A's was
          # rewritten to the standby by its failover response and a healthy
          # standby is a valid sticky target, so it STAYS on the standby;
          # jar B's still names the primary (its 503s carried no cookie), so
          # it resumes exactly where it broke.
          check_host_exact_jar "stickyfailover: failed-over session stays on standby" \
            "$BASE_HTTP/stickyfailover/messages" "$STICKY_DIR/sfa.jar" node-backend-sf-standby
          check_host_exact "stickyfailover: fresh client back on primary" \
            "$BASE_HTTP/stickyfailover/messages" node-backend-sf-primary
          check_host_exact_jar "stickyfailover: strict session resumes on primary" \
            "$BASE_HTTP/stickyfailover-strict/messages" "$STICKY_DIR/sfb.jar" node-backend-sf-primary
        else
          failed "stickyfailover: primary did not come back healthy after restart"
        fi
      else
        failed "stickyfailover: could not stop node-backend-sf-primary"
      fi
```

- [ ] **Step 2: Run the smoke suite for this profile**

Run: `scripts/smoke.sh stickyfailover`
Expected: `summary: 18 passed, 0 failed`. If a recovery check fails with the *other* host, re-read the failing check name — each name states which landing spot it asserts; a wrong host there means the warm request or the `--wait` timing was skipped, not a scheduling flake.

- [ ] **Step 3: Run it twice more to shake out flakiness**

Run: `scripts/smoke.sh stickyfailover && scripts/smoke.sh stickyfailover`
Expected: `summary: 18 passed, 0 failed` both times. Any intermittent failure here must be fixed before proceeding (timing-sensitive assertions are not acceptable; the checks are designed to be deterministic).

- [ ] **Step 4: Commit**

```bash
git add scripts/smoke.sh
git commit -m "test(smoke): stickyfailover outage and recovery choreography"
```

---

## Task 4: CI coverage

**Files:**
- Modify: `.github/workflows/ci.yml` (build step profile list)
- Modify: `.github/compose.cache.yml` (two new gha-cache service entries)

**Interfaces:**
- Consumes: services from Task 1. No new interfaces.

- [ ] **Step 1: Add the profile to the CI build**

In `.github/workflows/ci.yml`, change the build step's compose line to append the new profile:

```yaml
          docker compose \
            -f docker-compose.yml \
            -f .github/compose.cache.yml \
            --profile java --profile nginx --profile node --profile python --profile balanced --profile failover --profile sticky --profile busy --profile stickyfailover \
            build
```

- [ ] **Step 2: Add the cache entries**

In `.github/compose.cache.yml`, after the `node-backend-busy-2:` block and at the end of the `services:` mapping, append (sharing the existing `node-backend` scope, like every other node replica):

```yaml
  node-backend-sf-primary:
    build:
      context: ./backends/node
      cache_from: ["type=gha,scope=node-backend"]
      cache_to: ["type=gha,mode=max,scope=node-backend"]
  node-backend-sf-standby:
    build:
      context: ./backends/node
      cache_from: ["type=gha,scope=node-backend"]
      cache_to: ["type=gha,mode=max,scope=node-backend"]
```

- [ ] **Step 3: Validate the merged Compose config locally**

Run: `docker compose -f docker-compose.yml -f .github/compose.cache.yml --profile stickyfailover config --quiet`
Expected: no output, exit 0 (both files parse and merge).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml .github/compose.cache.yml
git commit -m "ci: build the stickyfailover profile with layer cache"
```

---

## Task 5: Documentation and backlog

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `docs/BACKLOG.md`

**Interfaces:**
- Consumes: the finished feature from Tasks 1–3. No code interfaces.

- [ ] **Step 1: README intro sentence**

After the `busy` sentence (line 16, "An eighth profile, `busy`, ... [Busy demo](#busy-demo-bybusyness)."), add:

```markdown
A ninth profile, `stickyfailover`, combines session affinity with a hot
standby at `/stickyfailover/` and `/stickyfailover-strict/` — see
[Sticky failover demo](#sticky-failover-demo).
```

- [ ] **Step 2: README architecture diagram**

Replace the final `/busy/` branch (the current `└─▶ /busy/` line and its three detail lines) with this five-branch tail — `/busy/` becomes a `├─▶` branch with its detail lines prefixed by `│  `, and the two new branches follow:

```
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

- [ ] **Step 3: README services table**

After the `node-backend-busy-1, node-backend-busy-2` row, add:

```markdown
| node-backend-sf-primary, node-backend-sf-standby | `node:22-alpine` (same build as `node-backend`) | `stickyfailover` | none | `/stickyfailover/` and `/stickyfailover-strict/` (via `balancer://stickyfailover(-strict)`) |
```

- [ ] **Step 4: README quickstart profile list**

Change "To run every backend, list all eight profiles:" to "...all nine profiles:" and append `--profile stickyfailover` to the command.

- [ ] **Step 5: README routes table**

After the `/busy/messages` row, add:

```markdown
| `GET /stickyfailover/messages` | `balancer://stickyfailover` | `stickyfailover` | JSON; a pinned session moves to `-standby` while the primary is down and **stays there** after recovery |
| `GET /stickyfailover-strict/messages` | `balancer://stickyfailover-strict` | `stickyfailover` | JSON while healthy; **503** for a pinned client while its member is down |
```

- [ ] **Step 6: README demo section**

After the "Busy demo (bybusyness)" section and before "## Tests", add:

```markdown
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
```

- [ ] **Step 7: README remaining touches**

- "## Tests" section: change `scripts/smoke.sh               # all eight profiles — 37 checks` to `# all nine profiles — 51 checks`.
- CI paragraph: change "the `sticky` pair and the `busy` pair are nine services sharing the single node image" to name the `stickyfailover` pair as well — "...the `sticky` pair, the `busy` pair and the `stickyfailover` pair are eleven services sharing the single node image".
- "## Configuration model" sites list, after the `27-busy.conf` bullet, add:

```markdown
  - `28-stickyfailover.conf` — sticky hot standby: TWO `<Proxy>` blocks over
    the same member pair; `balancer://stickyfailover` is the default
    (a pinned session fails over to the standby and stays there after
    recovery) and `balancer://stickyfailover-strict` adds `nofailover=On`
    (a pinned session breaks with 503 instead). Worker parameters on the
    `BalancerMember` lines, same rule as 24.
```

- Healthchecks paragraph: replace "`node-backend`, and the three balanced replicas (`node-backend-1/2/3`), the failover pair (`node-backend-primary`/`node-backend-standby`), the sticky pair (`node-backend-sticky-1`/`-2`) and the busy pair (`node-backend-busy-1`/`-2`) probe" — adjusting to the sentence actually in the file if it differs — so the enumeration ends "...the sticky pair (`node-backend-sticky-1`/`-2`), the busy pair (`node-backend-busy-1`/`-2`) and the stickyfailover pair (`node-backend-sf-primary`/`-standby`) probe".

- [ ] **Step 8: CLAUDE.md**

Four edits:

1. Project table — after the `/busy/` row, add:

```markdown
| `/stickyfailover/`, `/stickyfailover-strict/` | `balancer://stickyfailover(-strict)` → node-backend-sf-primary/standby | `stickyfailover` | 2× node: sticky + hot standby (`nofailover` contrast) |
```

2. Commands — in the big comment block, add a line `docker compose --profile stickyfailover up -d --build  # sticky + hot-standby combo demo`, and extend the "every backend" command with `--profile stickyfailover`.

3. Structure — change "all fourteen services" to "all sixteen services"; extend the services enumeration with "the `stickyfailover` pair"; after the `27-busy.conf` entry add "`28-stickyfailover.conf` (two balancers over one sticky primary + `status=+H` standby pair: default failover vs `nofailover=On` session break)". Update the smoke-suite comment to "all profiles (51 checks)".

4. Conventions — after the "Sticky routes need the route string in four places." bullet, add:

```markdown
- **A sticky standby needs its own route, and failover rewrites the pin.**
  Give the `status=+H` member a `route=`/`ROUTE` like any other (a session
  that lands on it must be able to pin there, or it degrades to
  round-robin). With the default `nofailover=Off` a pinned session moves to
  the standby and its cookie is rewritten, so it never migrates home — only
  new clients re-elect the recovered primary. `nofailover=On` breaks the
  session (503) instead, and it resumes on the primary after recovery.
```

- [ ] **Step 9: Move backlog item 1 to Shipped**

In `docs/BACKLOG.md`:

1. Delete the entire "### 1. Sticky sessions interacting with failover members" section.
2. Renumber the remaining open items 1–4 (URL-embedded session ids, non-node backend in a balancer, more balancer members, Swarm integration) and fix the intro sentence if it counts items.
3. Append to "Shipped from this backlog":

```markdown
- **Sticky sessions interacting with failover members** — deferred
  2026-08-27 in the sticky design, shipped 2026-08-30 as the
  `stickyfailover` profile (`28-stickyfailover.conf`,
  `node-backend-sf-primary/standby`; also demonstrates `nofailover=On`).
```

- [ ] **Step 10: Run the full suite**

Run: `scripts/smoke.sh`
Expected: `summary: 51 passed, 0 failed`.

- [ ] **Step 11: Commit**

```bash
git add README.md CLAUDE.md docs/BACKLOG.md
git commit -m "docs: stickyfailover demo; backlog item 1 shipped"
```

---

## Verification (whole feature)

- `scripts/smoke.sh stickyfailover` → 18 passed, 0 failed.
- `scripts/smoke.sh` → 51 passed, 0 failed.
- `docker compose -f docker-compose.yml -f .github/compose.cache.yml --profile stickyfailover config --quiet` → exit 0.
- `grep -c check scripts/smoke.sh` sanity: case checks for `stickyfailover` total 14 (5 steady + 2 pin + 4 outage + 3 recovery).
