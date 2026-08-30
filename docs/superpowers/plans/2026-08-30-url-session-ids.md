# URL-Embedded Session Ids Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the existing `sticky` profile pin clients by a `SESSIONID` embedded in the request URL — query-string form `?SESSIONID=<id>.<route>` and servlet-style `;SESSIONID=<id>.<route>` — including URL-over-cookie precedence and unknown-route fallback, with smoke regression checks and docs.

**Architecture:** Extends the existing `balancer://sticky` and its two node services; no new services, profile, or Apache modules. One balancer parameter (`scolonpathdelim=On` in the existing `ProxySet`) plus a one-line node path fix (strip the `;`-segment, as a servlet container would) make both URL forms work end-to-end; four deterministic smoke checks (the URL names the member) guard them; docs cover the forms, precedence, and the `stickyforce`-doesn't-exist correction.

**Tech Stack:** Apache httpd 2.4 `mod_proxy_balancer` (`stickysession`, `scolonpathdelim`), the existing zero-dependency node backend (`node:http`), the existing smoke suite (POSIX sh + curl).

**Spec:** `docs/superpowers/specs/2026-08-30-url-session-ids-design.md` (approved).

## Global Constraints

- Apache 2.4-only syntax. `scolonpathdelim=On` is a **balancer** parameter: it goes in the `ProxySet` inside the `<Proxy "balancer://sticky">` block, never on a `BalancerMember` line and never on the `ProxyPass`.
- The node change is exactly `req.url.split('?')[0].split(';')[0]` for the path; `?delay=` parsing (which reads the query string isolated by the first `split('?')`) is untouched.
- No new Compose services, no new profile, no `httpd.conf` change (module count stays 18), no new smoke helpers — the four checks use existing `check_host_exact`, `check_host_exact_jar`, `check_status`, and `STICKY_DIR`.
- The two pin checks name DIFFERENT members on purpose (query form pins `node-backend-sticky-2`, servlet form pins `node-backend-sticky-1`); the precedence check's jar `"$STICKY_DIR/u.jar"` is seeded deterministically via the servlet-form URL before the assertion.
- All four checks are deterministic — the URL names the member; no scheduling-dependent assertion, no timing assertion, no new sleeps.
- Suite counts: `sticky`-alone goes 9 → 13 case+preamble checks (4 preamble + 9 case); full suite goes **51 → 55**.
- Conventional commits; run `scripts/smoke.sh sticky` (or the full suite where stated) before committing; `docs/REVIEW.md` is frozen — never edit it.
- Only these files change across the whole plan: `reverse-proxy/apacheconf/sites/26-sticky.conf`, `backends/node/server.js`, `scripts/smoke.sh`, `README.md`, `CLAUDE.md`, `docs/BACKLOG.md`.

---

## Task 1: Enable URL embedding (proxy config + node path fix)

**Files:**
- Modify: `reverse-proxy/apacheconf/sites/26-sticky.conf`
- Modify: `backends/node/server.js`

**Interfaces:**
- Produces: `GET /sticky/messages?SESSIONID=<id>.<route>` and `GET /sticky/messages;SESSIONID=<id>.<route>` both return the standard node JSON from the named member (consumed by Task 2's checks). No change to any existing route, cookie behavior, or response body.

- [ ] **Step 1: Update `26-sticky.conf`**

Two edits. First, extend the header comment — after the line `clients fall through to plain round-robin.` add:

```apache
# The session id may also arrive embedded in the request URL, in either
# form: ?SESSIONID=<id>.<route> (query string, always enabled) or
# ;SESSIONID=<id>.<route> (servlet-style path parameter, enabled by
# scolonpathdelim=On). A URL parameter takes precedence over the cookie;
# an unknown route id is ignored (round-robin).
```

Second, change the `ProxySet` line inside the `<Proxy "balancer://sticky">` block from:

```apache
    ProxySet lbmethod=byrequests stickysession=SESSIONID
```

to:

```apache
    ProxySet lbmethod=byrequests stickysession=SESSIONID scolonpathdelim=On
```

Leave both `BalancerMember` lines and the `ProxyPass`/`ProxyPassReverse` pair exactly as they are.

- [ ] **Step 2: Fix the node path parsing**

In `backends/node/server.js`, two edits. First, extend the header comment — after the line `// for that many milliseconds so a balancer demo can keep one member busy.` add:

```js
// A ";" path segment (;SESSIONID=...) is stripped from the path: the proxy
// leaves it in the proxied request, and servlet containers strip it
// themselves — without this the route would 404.
```

Second, change line 17 (inside the request handler) from:

```js
  const path = req.url.split('?')[0];
```

to:

```js
  const path = req.url.split('?')[0].split(';')[0];
```

Change nothing else — `params` still parses the full `req.url`, so `?delay=` works unchanged.

- [ ] **Step 3: Rebuild and verify no regression**

Run: `scripts/smoke.sh sticky`
Expected: `summary: 9 passed, 0 failed` — the existing 5 case checks (JSON, https, rotation, jar A, jar B) plus 4 preamble checks. The proxy and node images rebuild inside the run. If the proxy fails to start, check `docker compose logs reverse-proxy` for a syntax error in `26-sticky.conf`.

- [ ] **Step 4: Manually confirm both URL forms before writing the checks**

Run:

```sh
docker compose --profile sticky up -d --build >/dev/null 2>&1
curl -fsS "http://localhost:8080/sticky/messages?SESSIONID=x.node-backend-sticky-2" | grep -o '"host":"[^"]*"'
curl -fsS "http://localhost:8080/sticky/messages;SESSIONID=x.node-backend-sticky-1" | grep -o '"host":"[^"]*"'
docker compose --profile sticky down >/dev/null 2>&1
```

Expected: first prints `"host":"node-backend-sticky-2"`, second prints `"host":"node-backend-sticky-1"`. If the second returns 404, the node `;`-split is not in the rebuilt image; if it rotates, `scolonpathdelim=On` is missing from the `ProxySet`.

- [ ] **Step 5: Commit**

```bash
git add reverse-proxy/apacheconf/sites/26-sticky.conf backends/node/server.js
git commit -m "feat(proxy): URL-embedded session ids in the sticky balancer"
```

---

## Task 2: Four smoke checks

**Files:**
- Modify: `scripts/smoke.sh` (the `sticky)` case only)

**Interfaces:**
- Consumes: the URL forms from Task 1; existing helpers `check_host_exact` (6 plain fetches, every `host` must equal the expected value), `check_host_exact_jar` (same through a cookie jar), `check_status` (HTTP status assertion), and the existing `STICKY_DIR` temp dir.
- Produces: four new checks in the `sticky)` case; suite total 55.

- [ ] **Step 1: Add the checks**

In `scripts/smoke.sh`, inside the `sticky)` case, after the `check_host_constant "sticky: jar B pinned"` line and before the `;;`, add:

```sh
      check_host_exact "sticky: query-form URL pins" \
        "$BASE_HTTP/sticky/messages?SESSIONID=x.node-backend-sticky-2" node-backend-sticky-2
      check_host_exact "sticky: servlet-form URL pins" \
        "$BASE_HTTP/sticky/messages;SESSIONID=x.node-backend-sticky-1" node-backend-sticky-1
      # Seed u.jar deterministically via the servlet form (that member's
      # Set-Cookie fills the jar with sticky-1's route), then let the URL
      # parameter name the other member: the URL wins over the cookie.
      curl -fsS -c "$STICKY_DIR/u.jar" -b "$STICKY_DIR/u.jar" \
        "$BASE_HTTP/sticky/messages;SESSIONID=x.node-backend-sticky-1" >/dev/null 2>&1 || true
      check_host_exact_jar "sticky: URL param overrides cookie" \
        "$BASE_HTTP/sticky/messages?SESSIONID=x.node-backend-sticky-2" "$STICKY_DIR/u.jar" node-backend-sticky-2
      check_status "sticky: unknown URL route falls back to 200" 200 \
        "$BASE_HTTP/sticky/messages?SESSIONID=x.no-such-route"
```

Nothing else in the file changes.

- [ ] **Step 2: Run the profile suite**

Run: `scripts/smoke.sh sticky`
Expected: `summary: 13 passed, 0 failed` (4 preamble + 9 case). If "servlet-form URL pins" fails with rotation, `scolonpathdelim=On` is absent; if "URL param overrides cookie" returns sticky-1, precedence is inverted — re-read the check, do not weaken it.

- [ ] **Step 3: Run it twice more to shake out flakiness**

Run: `scripts/smoke.sh sticky && scripts/smoke.sh sticky`
Expected: `summary: 13 passed, 0 failed` both times. Any intermittent failure must be diagnosed and fixed before committing — the checks are deterministic by construction (the URL names the member).

- [ ] **Step 4: Commit**

```bash
git add scripts/smoke.sh
git commit -m "test(smoke): URL-embedded session id checks for the sticky balancer"
```

---

## Task 3: Documentation and backlog

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `docs/BACKLOG.md`

**Interfaces:**
- Consumes: the finished behavior from Tasks 1–2. No code interfaces.

- [ ] **Step 1: README — sticky demo section**

In `## Sticky sessions demo`, after the paragraph beginning "A second jar" (the one ending "...affinity is per client, not global.") and before the paragraph beginning "`/balancer-manager` lists", insert:

```markdown
The session id can also travel in the URL itself, no cookie required —
the same `stickysession=SESSIONID` reads it. Two forms: a query
parameter (`?SESSIONID=<id>.<route>`, always enabled) and the
servlet-style path parameter (`;SESSIONID=<id>.<route>`, enabled by
`scolonpathdelim=On` in `26-sticky.conf`; the node app strips the
`;`-segment the way a servlet container would). A URL parameter takes
precedence over a cookie, and an unknown route id is simply ignored
(round-robin):

```sh
# pin by query parameter — lands on sticky-2
curl -s "http://localhost:8080/sticky/messages?SESSIONID=x.node-backend-sticky-2" | grep -o '"host":"[^"]*"'

# pin by servlet-style path parameter — lands on sticky-1
curl -s "http://localhost:8080/sticky/messages;SESSIONID=x.node-backend-sticky-1" | grep -o '"host":"[^"]*"'

# a URL parameter beats the cookie: jar pinned to sticky-1, URL says sticky-2
curl -s -c jar.txt -b jar.txt "http://localhost:8080/sticky/messages;SESSIONID=x.node-backend-sticky-1" >/dev/null
curl -s -c jar.txt -b jar.txt "http://localhost:8080/sticky/messages?SESSIONID=x.node-backend-sticky-2" | grep -o '"host":"[^"]*"'

# unknown route id: no error, plain round-robin
curl -s "http://localhost:8080/sticky/messages?SESSIONID=x.no-such-route" | grep -o '"host":"[^"]*"'
```

httpd 2.4 has no `stickyforce` knob (the name floats around old mailing
lists); the behavior people usually mean by it — a pinned session
breaking with 503 instead of failing over — is `nofailover=On`, which
the [stickyfailover demo](#sticky-failover-demo) shows. The proxy never
rewrites session ids into response URLs: embedding them in the links it
serves is the backend's job (servlet containers do it when they render
pages).
```

- [ ] **Step 2: README — routes table and demo intro**

- Routes table, `GET /sticky/messages` row: change the Response cell to `JSON; host is constant per client cookie, alternating without one; ?SESSIONID=<id>.<route> or ;SESSIONID=... in the URL pins without a cookie and overrides the cookie`.
- Intro paragraph (line ~13): change "A seventh profile, `sticky`, pins each client to one member via a session cookie at `/sticky/`" to "...pins each client to one member via a session cookie or a URL-embedded session id at `/sticky/`".

- [ ] **Step 3: README — configuration model**

The `26-sticky.conf` bullet in the sites list: after "`ProxySet stickysession=SESSIONID` — the balancer routes by the `.`-suffix of the client's `SESSIONID` cookie." insert "`scolonpathdelim=On` additionally lets the same id arrive as the servlet-style path parameter `;SESSIONID=...` (the query-string form needs nothing); a URL parameter takes precedence over the cookie."

- [ ] **Step 4: README — tests count**

In `## Tests`: change `scripts/smoke.sh               # all nine profiles — 51 checks` to `# all nine profiles — 55 checks`.

- [ ] **Step 5: CLAUDE.md**

Two edits:

1. Structure section, the `26-sticky.conf` entry (it wraps across two lines at `CLAUDE.md:77-78`) — change:
   ```
     `26-sticky.conf` (`balancer://sticky` session affinity:
     `node-backend-sticky-1/2` with `route=` + `stickysession=SESSIONID`),
   ```
   to:
   ```
     `26-sticky.conf` (`balancer://sticky` session affinity:
     `node-backend-sticky-1/2` with `route=` + `stickysession=SESSIONID` +
     `scolonpathdelim=On` for `;SESSIONID=` URL embedding),
   ```
2. The smoke-suite comment "all profiles (51 checks)" becomes "all profiles (55 checks)".

- [ ] **Step 6: Backlog — ship item 1**

In `docs/BACKLOG.md`:

1. Delete the entire "### 1. URL-embedded session ids" section.
2. Renumber the remaining open items 1–3 (a non-node backend inside a balancer, more balancer members, Swarm integration).
3. Append to "Shipped from this backlog":

```markdown
- **URL-embedded session ids** — deferred 2026-08-27 in the sticky
  design, shipped 2026-08-30 as an extension of the `sticky` profile
  (`scolonpathdelim=On` in `26-sticky.conf`, `;`-path stripping in the
  node backend; query and servlet forms, URL-over-cookie precedence).
```

- [ ] **Step 7: Run the full suite**

Run: `scripts/smoke.sh`
Expected: `summary: 55 passed, 0 failed`.

- [ ] **Step 8: Commit**

```bash
git add README.md CLAUDE.md docs/BACKLOG.md
git commit -m "docs: URL-embedded session ids; backlog item 1 shipped"
```

---

## Verification (whole feature)

- `scripts/smoke.sh sticky` → 13 passed, 0 failed (three consecutive runs).
- `scripts/smoke.sh` → 55 passed, 0 failed.
- `curl` spot-checks from Task 1 Step 4 both name the URL-pinned member.
