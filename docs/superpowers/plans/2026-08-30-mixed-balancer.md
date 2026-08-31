# Mixed-Stack Balancer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `mixed` Compose profile putting the python backend inside a `mod_proxy_balancer` pool next to a node member (`balancer://mixed` at `/mixed/`), proving the balancer is backend-agnostic, with smoke checks asserting both stacks serve.

**Architecture:** Drop-in demo following the repo's established conventions — two profile-gated Compose services with explicit `hostname:` keys, one numbered server-level site config, config baked into the image (rebuild, never reload). Zero backend code changes: python's `/messages` already returns the same JSON shape as node's. No new httpd modules.

**Tech Stack:** Apache httpd 2.4 (`mod_proxy_balancer`, `lbmethod=byrequests`), Docker Compose profiles, the existing zero-dependency node and python backends.

**Spec:** `docs/superpowers/specs/2026-08-30-mixed-balancer-design.md` (approved).

## Global Constraints

- Apache 2.4-only syntax; server-level directives only (no vhost edits); the route must work identically on :8080 and the :443 vhost.
- `retry=0` on both `BalancerMember` lines, and **only** there — on a `balancer://` `ProxyPass`, `key=value` params are balancer params and httpd rejects worker params (rule documented in `24-balanced.conf`).
- Healthchecks probe `127.0.0.1`, live in docker-compose.yml only. No published ports for backends.
- No changes to `backends/node/server.js` or `backends/python/server.py`.
- Names are load-bearing and appear in three places that must agree: service name = `hostname:` key = host in the `BalancerMember` URL (`node-backend-mixed-1`, `python-backend-mixed-1`). Route `/mixed/`, balancer `balancer://mixed`, profile `mixed`, site config `29-mixed.conf`.
- gha cache entries carry `scope=`; `node-backend-mixed-1` shares scope `node-backend`, `python-backend-mixed-1` shares scope `python-backend`.
- Conventional commits; each task ends verified and committed; run the relevant smoke subset before committing.
- Counts move: services 16 → 18, default profiles 9 → 10, full-suite checks 55 → 59; `mixed`-alone smoke = 8 (4 proxy + 4 mixed). References in README, CLAUDE.md, and the smoke.sh header comment all updated.
- Never a timing assertion in smoke. Single-request checks over `/mixed/` must be stack-agnostic (both members answer alternately); stack diversity is asserted across a 12-fetch loop.
- `docs/REVIEW.md` is frozen — never edit it. `docs/BACKLOG.md` is updated by this feature (item 1 moves to Shipped).

---

## Task 1: Compose services + balancer route

**Files:**
- Modify: `docker-compose.yml` (after the `node-backend-sf-standby` block, before `networks:`)
- Create: `reverse-proxy/apacheconf/sites/29-mixed.conf`
- Modify: `.github/compose.cache.yml` (after the `node-backend-sf-standby` entry)
- Modify: `.github/workflows/ci.yml:26` (build-step profile list)

**Interfaces:**
- Produces: route `GET /mixed/messages` on :8080 and :8443 — JSON whose `backend` field alternates `node`/`python` per request and whose `host` field alternates `node-backend-mixed-1`/`python-backend-mixed-1`. Consumed by Task 2 (smoke checks) and Task 3 (docs walkthrough).

- [ ] **Step 1: Add the two services to `docker-compose.yml`**

Insert after the `node-backend-sf-standby` service block (line 232, just before `networks:`), matching the file's two-space indent:

```yaml
  node-backend-mixed-1:
    build: ./backends/node
    hostname: node-backend-mixed-1
    profiles: ["mixed"]
    restart: unless-stopped
    networks:
      - proxy-net
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/messages"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s

  python-backend-mixed-1:
    build: ./backends/python
    hostname: python-backend-mixed-1
    profiles: ["mixed"]
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

- [ ] **Step 2: Create `reverse-proxy/apacheconf/sites/29-mixed.conf`**

```apache
# /mixed/... -> balancer://mixed (one node + one python member, Compose
# profile "mixed"). Round-robin alternates stacks per request - the balancer
# only speaks HTTP; the members' "backend"/"host" JSON fields show the
# alternation.
# (retry=0 lives on the BalancerMember lines: on a balancer:// ProxyPass,
# key=value params are balancer params and httpd rejects worker params here.)
<Proxy "balancer://mixed">
    BalancerMember "http://node-backend-mixed-1:8080" retry=0
    BalancerMember "http://python-backend-mixed-1:8080" retry=0
    ProxySet lbmethod=byrequests
</Proxy>
ProxyPass        "/mixed/" "balancer://mixed/"
ProxyPassReverse "/mixed/" "balancer://mixed/"
```

- [ ] **Step 3: Add cache entries to `.github/compose.cache.yml`**

Append after the `node-backend-sf-standby` entry, matching indent:

```yaml
  node-backend-mixed-1:
    build:
      context: ./backends/node
      cache_from: ["type=gha,scope=node-backend"]
      cache_to: ["type=gha,mode=max,scope=node-backend"]
  python-backend-mixed-1:
    build:
      context: ./backends/python
      cache_from: ["type=gha,scope=python-backend"]
      cache_to: ["type=gha,mode=max,scope=python-backend"]
```

- [ ] **Step 4: Add the profile to the CI build step**

`.github/workflows/ci.yml` line 26 — append `--profile mixed` to the profile list:

```yaml
            --profile java --profile nginx --profile node --profile python --profile balanced --profile failover --profile sticky --profile busy --profile stickyfailover --profile mixed \
```

(The smoke step runs `scripts/smoke.sh` with no args, so it picks `mixed` up automatically once Task 2 adds it to the default list — no CI smoke edit needed.)

- [ ] **Step 5: Verify the route live**

The proxy image bakes config in at build time — rebuild, never reload. If `reverse-proxy/certs/server.crt` is missing, run `scripts/gen-dev-certs.sh` first.

```sh
docker compose --profile mixed up -d --build --wait
```

Then:

```sh
for i in 1 2 3 4 5 6; do
  curl -s http://localhost:8080/mixed/messages | grep -o '"backend":"[^"]*"'
done
```

Expected: six lines alternating `"backend":"node"` / `"backend":"python"` (byrequests round-robin over two members). Then:

```sh
curl -sk https://localhost:8443/mixed/messages | grep -o '"backend":"[^"]*"'   # 200, either stack
curl -s http://localhost:8080/balancer-manager | grep -o 'balancer://mixed'    # one hit
docker compose --profile mixed down
```

Expected: TLS route returns 200 with JSON; the dashboard lists `balancer://mixed`.

- [ ] **Step 6: Commit**

```sh
git add docker-compose.yml reverse-proxy/apacheconf/sites/29-mixed.conf .github/compose.cache.yml .github/workflows/ci.yml
git commit -m "feat(proxy): mixed-stack balancer profile (node + python members)"
```

---

## Task 2: smoke checks for the mixed route

**Files:**
- Modify: `scripts/smoke.sh` (header comment, default profile list, new helper after `check_rotates`, new case block after `stickyfailover)`)

**Interfaces:**
- Consumes: the live `/mixed/messages` route from Task 1.
- Produces: helper `check_both_backends <name> <url> <backend-a> <backend-b>` — 12 fetches, passes when both backend identifiers appear in the accumulated bodies. Default profile list includes `mixed`; full-suite expectation becomes 59.

- [ ] **Step 1: Update the header comment and default profile list**

Line 4 comment: `default: all nine` becomes `default: all ten`. Line 20 default list gains `mixed` at the end:

```sh
  PROFILES="java nginx node python balanced failover sticky busy stickyfailover mixed"
```

- [ ] **Step 2: Add the `check_both_backends` helper**

Insert immediately after the `check_rotates` function (after its closing `}` at line 73):

```sh
# check_both_backends <name> <url> <backend-a> <backend-b> — fetches 12
# times; both backend identifiers must appear across the accumulated bodies
# (round-robin over two stacks alternates; one missing means the balancer
# is not actually mixing, or a member is down).
check_both_backends() {
  name="$1"; url="$2"; want_a="$3"; want_b="$4"
  bodies=""
  i=0
  while [ "$i" -lt 12 ]; do
    b="$(curl -fsS "$url" 2>/dev/null)" || b=""
    bodies="$bodies$b"
    i=$((i + 1))
  done
  if printf '%s' "$bodies" | grep -qF "\"backend\":\"$want_a\"" && \
     printf '%s' "$bodies" | grep -qF "\"backend\":\"$want_b\""; then
    ok "$name"
  else
    failed "$name - did not see both '$want_a' and '$want_b' backends from $url"
  fi
}
```

- [ ] **Step 3: Add the `mixed)` case block**

In the per-profile `case` statement, insert after the `stickyfailover)` block's closing `;;` (before `*)`):

```sh
    mixed)
      check_both_backends "mixed: both stacks serve" "$BASE_HTTP/mixed/messages" node python
      check_rotates "mixed: host rotation (>=2)" "$BASE_HTTP/mixed/messages" 2
      check "mixed: X-Forwarded-Proto=http" "$BASE_HTTP/mixed/messages" '"x_forwarded_proto":"http"'
      check "mixed: X-Forwarded-Proto=https behind TLS" "$BASE_HTTPS/mixed/messages" '"x_forwarded_proto":"https"' -k
      ;;
```

(Both single-request checks grep `x_forwarded_proto`, which both stacks emit with the same value — a `"backend":"..."` grep would depend on which member answered.)

- [ ] **Step 4: Run the smoke subset**

```sh
scripts/smoke.sh mixed
```

Expected final line: `summary: 8 passed, 0 failed` (4 proxy + 4 mixed), exit 0.

- [ ] **Step 5: Commit**

```sh
git add scripts/smoke.sh
git commit -m "test(smoke): mixed-stack balancer checks"
```

---

## Task 3: documentation

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `reverse-proxy/apacheconf/htdocs/index.html`
- Modify: `docs/BACKLOG.md`

**Interfaces:**
- Consumes: the shipped `mixed` profile (Tasks 1–2) and its observed behavior.
- Produces: documentation consistent with the live system; BACKLOG item 1 in "Shipped".

- [ ] **Step 1: README — intro paragraph**

After the `stickyfailover` sentence block (line 18-20, "...see [Sticky failover demo](#sticky-failover-demo)."), append:

```markdown
A tenth profile, `mixed`, puts a node and a python backend behind one
round-robin balancer at `/mixed/` — see
[Mixed-stack balancer demo](#mixed-stack-balancer-demo).
```

- [ ] **Step 2: README — architecture diagram**

In the `proxy-net` tree, insert a `/mixed/` branch before the final `/stickyfailover-strict/` branch (which keeps its `└─▶` connector; the new branch uses `├─▶`):

```
                              ├─▶ /mixed/   ─▶ balancer://mixed    (profile mixed)
                              │                 byrequests round-robin over two stacks:
                              │                 ├─▶ node-backend-mixed-1   :8080
                              │                 └─▶ python-backend-mixed-1 :8080
```

- [ ] **Step 3: README — service table row**

After the `node-backend-sf-primary, node-backend-sf-standby` row (line 71):

```markdown
| node-backend-mixed-1, python-backend-mixed-1 | `node:22-alpine` + `python:3.12-alpine` (same builds as `node-backend` / `python-backend`) | `mixed` | none | `/mixed/` (via `balancer://mixed`) |
```

- [ ] **Step 4: README — quickstart profile list**

Line 94: "list all nine profiles" becomes "list all ten profiles"; the command on line 97 gains `--profile mixed` at the end:

```sh
docker compose --profile java --profile nginx --profile node --profile python --profile balanced --profile failover --profile sticky --profile busy --profile stickyfailover --profile mixed up -d --build
```

- [ ] **Step 5: README — routes table row**

After the `GET /stickyfailover-strict/messages` row (line 121):

```markdown
| `GET /mixed/messages` | `balancer://mixed` | `mixed` | JSON; `backend` alternates `node`/`python` per request, `host` alternating with it |
```

- [ ] **Step 6: README — demo walkthrough section**

Insert a new `## Mixed-stack balancer demo` section between `## Sticky failover demo` (ends line 382) and `## Tests` (line 384):

````markdown
## Mixed-stack balancer demo

The `mixed` profile proves the balancer only speaks HTTP: it puts the node
backend and the python backend behind one `balancer://mixed`
(`reverse-proxy/apacheconf/sites/29-mixed.conf`, plain `byrequests`
round-robin — the same method as the `balanced` demo, but the members are
different stacks). Every request alternates stacks; watch the `backend` and
`host` fields flip together:

```sh
docker compose --profile mixed up -d --build

for i in 1 2 3 4; do
  curl -s http://localhost:8080/mixed/messages | grep -o '"backend":"[^"]*"'
done
# "backend":"node", "backend":"python", node, python ...

curl -sk https://localhost:8443/mixed/messages   # same route over TLS
docker compose --profile mixed down
```

Neither backend was changed for this — python's `/messages` already returns
the same JSON shape as node's, with `host` echoing the container hostname
(`socket.gethostname()` where node uses `os.hostname()`). The balancer never
learns the stacks; it forwards HTTP and alternates members.
`/balancer-manager` lists both members of `balancer://mixed`.
````

- [ ] **Step 7: README — tests section counts**

Line 392: `scripts/smoke.sh               # all nine profiles — 55 checks` becomes:

```markdown
scripts/smoke.sh               # all ten profiles — 59 checks
```

Lines 400-403 (CI paragraph): "the `busy` pair and the `stickyfailover` pair are eleven services sharing the single node image" becomes "...the `busy` pair, the `stickyfailover` pair and the `mixed` node member are thirteen services sharing the single node image" (node-image services: `node-backend`, `1/2/3`, primary/standby, sticky-1/2, busy-1/2, sf-primary/standby, mixed-1 = 13; the python member shares the python image).

- [ ] **Step 8: CLAUDE.md updates**

Five edits:

1. Profile table — after the `stickyfailover` row:

```markdown
| `/mixed/` | `balancer://mixed` → node-backend-mixed-1 + python-backend-mixed-1 | `mixed` | node + python behind one round-robin balancer (backend-agnostic demo) |
```

2. Commands section — the all-profiles `up` line gains `--profile mixed`; the parenthetical comment gains `mixed: node+python in one balancer`; add a dedicated line after the `stickyfailover` one:

```sh
docker compose --profile mixed up -d --build        # mixed-stack balancer demo
```

3. Line 46: `# Test suite — all profiles (55 checks) or any subset` becomes `# Test suite — all profiles (59 checks) or any subset`.

4. Structure section, `docker-compose.yml` bullet: `all sixteen services` becomes `all eighteen services`; extend the enumeration with `the mixed node+python pair` after `the stickyfailover` pair.

5. Structure section, sites bullet — after the `28-stickyfailover.conf` description, add:

```markdown
`29-mixed.conf` (`balancer://mixed`: one node + one python member in a
`byrequests` round-robin — the backend-agnostic demo)
```

- [ ] **Step 9: Landing page route list**

`reverse-proxy/apacheconf/htdocs/index.html` — after the `stickyfailover` `<li>` (line 26), insert:

```html
    <li><code>GET /mixed/messages</code> — mixed-stack round-robin: one node and one python member alternate per request (<code>--profile mixed</code>)</li>
```

- [ ] **Step 10: BACKLOG.md — item 1 ships**

1. Delete the entire `### 1. A non-node backend inside a balancer` open item (heading through its `Sources:` block).
2. Renumber: `### 2. More balancer members` becomes `### 1.`, `### 3. Swarm integration` becomes `### 2.`, and the swarm item's "Largest scope item here" text stays as-is.
3. Append to `## Shipped from this backlog` (after the URL-embedded session ids entry):

```markdown
- **A non-node backend inside a balancer** — deferred 2026-08-25 in the
  balancer design (re-deferred by the failover and sticky designs), shipped
  2026-08-30 as the `mixed` profile (`29-mixed.conf`,
  `node-backend-mixed-1` + `python-backend-mixed-1` in one `byrequests`
  round-robin).
```

- [ ] **Step 11: Full-suite verification**

```sh
scripts/smoke.sh
```

Expected final line: `summary: 59 passed, 0 failed`, exit 0.

- [ ] **Step 12: Commit**

```sh
git add README.md CLAUDE.md reverse-proxy/apacheconf/htdocs/index.html docs/BACKLOG.md
git commit -m "docs: mixed-stack balancer demo"
```

---

## Self-review notes

- Spec coverage: compose services (Task 1.1), site conf (1.2), cache (1.3), CI (1.4), live verification (1.5), smoke helper + case + default list (2.1-2.3), README intro/diagram/tables/quickstart/walkthrough/tests counts (3.1-3.7), CLAUDE.md (3.8), landing page (3.9), BACKLOG (3.10), full suite (3.11). All spec sections mapped.
- No placeholders; all code blocks exact.
- Names consistent throughout: `node-backend-mixed-1`, `python-backend-mixed-1`, `balancer://mixed`, `/mixed/`, profile `mixed`, `29-mixed.conf`, helper `check_both_backends`.
