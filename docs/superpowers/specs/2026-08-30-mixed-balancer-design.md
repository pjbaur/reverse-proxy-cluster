# Mixed-Stack Balancer Design

**Date:** 2026-08-30
**Status:** approved by project owner
**Feature:** an optional, demonstrable `mixed` profile putting a non-node
backend (python) inside a `mod_proxy_balancer` pool, showing the balancer is
backend-agnostic.

## Problem

All five balancer demos (`balanced`, `failover`, `sticky`, `busy`,
`stickyfailover`) ride exclusively on the node backend. Nothing in the repo
demonstrates that `mod_proxy_balancer` cares only about HTTP, not about the
member's stack. "Non-node backends" is out of scope in the balancer, failover,
and sticky designs (2026-08-25/27) and sits as item 1 in `docs/BACKLOG.md`.
The owner wants an opt-in demo of one balancer electing between two different
stacks.

## Decision record

- **Mechanism: a new `balancer://mixed` with one node member and one python
  member, `lbmethod=byrequests`.** Round-robin over two members alternates
  stacks on every request — the demonstration *is* the alternation, visible
  in the `backend` and `host` JSON fields. No new modules, no new Apache
  mechanics; the only new thing under test is stack heterogeneity.
- **Python is the non-node stack.** `backends/python/server.py` already
  satisfies the member contract unchanged: `GET /messages` returns JSON with
  `backend`, `message`, `host` (`socket.gethostname()`, so it echoes the
  container hostname exactly like node's `os.hostname()`), and the echoed
  `X-Forwarded-*` headers. Rejected: nginx (serves `/messages` as a static
  file — the `host` field is baked in and cannot vary per member without an
  envsubst workaround that drags template machinery into a static demo) and
  java (satisfies the contract but 20 s start period and a heavy image buy no
  extra teaching value over python).
- **New dedicated profile, not a fourth member of `balancer://demo`.** The
  convention is one demo per profile, independently runnable and
  independently asserted; also keeps `balanced`'s homogeneous
  "three identical replicas" story and its `"backend":"node"` smoke checks
  intact. Folding a python member into `24-balanced.conf` would rewrite that
  demo's narrative and checks for no structural gain.
- **Topology: exactly two members** (`node-backend-mixed-1`,
  `python-backend-mixed-1`). A second same-stack member adds nothing —
  member-count growth is already backlog item 2.
- **`retry=0` on both members**, matching `24-balanced.conf` and
  `27-busy.conf`: no failure story in this demo, and `retry=0` keeps a
  stopped member re-elected immediately.
- **Assertion strategy splits by request scope.** A single request lands on
  one member, so single-request checks must be stack-agnostic (grep
  `"x_forwarded_proto":"http|https"`, which both stacks emit with the same
  value). Stack diversity is asserted across a 12-fetch loop: both
  `"backend":"node"` and `"backend":"python"` must appear (new helper), and
  both `host` values must appear (`check_rotates`, threshold 2).
- **Naming: `mixed` everywhere** — route `/mixed/`, balancer
  `balancer://mixed`, profile `mixed`, services `node-backend-mixed-1` /
  `python-backend-mixed-1`, site config `29-mixed.conf` (next free number) —
  matching the short prefixes `/balanced/`, `/failover/`, `/sticky/`,
  `/busy/`.

## Design

### Backend changes — none

Both backends are used exactly as built. The python image gains a second
consumer the way the node image already has seven. Explicit `hostname:` keys
on both services keep the JSON `host` field readable (`node-backend-mixed-1`,
`python-backend-mixed-1`) per the Compose convention.

### Compose services — `docker-compose.yml`

Two services, clones of the existing single-backend shapes:

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

No published ports; the python health probe uses `127.0.0.1` like the
existing `python-backend` service. Service count 16 → 18.

### Balancer configuration — `reverse-proxy/apacheconf/sites/29-mixed.conf`

```apache
# /mixed/... -> balancer://mixed (one node + one python member, Compose
# profile "mixed"). Round-robin alternates stacks per request — the balancer
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

Server-level directives only, so the route works identically on :8080 and the
:443 vhost (established inheritance model). No new `<Location>`: the global
`/balancer-manager` handler lists `balancer://mixed` alongside the others,
showing one row per member regardless of stack. `X-Forwarded-Proto`/`Port`
come from `10-proxy.conf` exactly as for every other member (already proven
by the `balanced` checks).

**Demo flow:** `docker compose --profile mixed up -d --build`, then
`curl localhost:8080/mixed/messages` repeatedly — the `backend` field
alternates `node`/`python` and the `host` field alternates with it; same over
`https://localhost:8443`; `/balancer-manager` shows both members of
`balancer://mixed`.

### smoke.sh — `scripts/smoke.sh`

`mixed` joins the default profile list (full run becomes 10 profiles). New
helper next to the other body-based checks:

```sh
# check_both_backends <name> <url> <backend-a> <backend-b> — fetches 12
# times; both backend identifiers must appear in the accumulated bodies
# (round-robin over two stacks alternates; one stack missing means the
# balancer is not actually mixing, or a member is down).
```

Implementation mirrors `check_rotates`: loop 12, `sed` out the `"backend"`
value per response, then assert both wanted strings are present in the
accumulated list. Case block, 4 checks:

1. **Mix check:** `check_both_backends` over `/mixed/messages` — both
   `node` and `python` appear in 12 fetches.
2. `check_rotates "mixed: host rotation (>=2)" /mixed/messages 2` — both
   members' `host` values appear.
3. `X-Forwarded-Proto=http` echoed through the mixed route (single fetch;
   both stacks emit the same value, so alternation is harmless).
4. Same shape over https: grep `"x_forwarded_proto":"https"` (single fetch;
   stack-agnostic by design — a `"backend":"..."` grep would depend on which
   member answered).

Full-suite check count rises from 55 to 59; `smoke.sh mixed` alone = 8
(4 proxy + 4).

### CI

`.github/workflows/ci.yml` build and smoke steps add `--profile mixed`.
`.github/compose.cache.yml` gains `node-backend-mixed-1` (scope
`node-backend`, shared context) and `python-backend-mixed-1` (scope
`python-backend`).

### Docs

- README: route table gains `/mixed/` → `balancer://mixed`; check-count
  references 55 → 59; service count 16 → 18; a short "Mixed-stack balancer"
  walkthrough section mirroring the busy section (start, curl twice, observe
  `backend`/`host` alternating, `/balancer-manager` note, the honest line
  that the balancer never learns the stacks — it forwards HTTP).
- CLAUDE.md: profile table gains the `/mixed/` row; Commands gains the mixed
  up/down; Structure bullets gain `29-mixed.conf`; service count 16 → 18.
- Landing page `reverse-proxy/apacheconf/htdocs/index.html`: route list gains
  `GET /mixed/messages`.
- `docs/BACKLOG.md`: item 1 (non-node backend in a balancer) moves from Open
  to Shipped; item numbering adjusts.

## Testing

- `httpd -t` in the rebuilt proxy container (implied by the smoke build).
- `scripts/smoke.sh mixed` — 8 passed, 0 failed.
- `scripts/smoke.sh` full — 59 passed, 0 failed.
- Manual demo verification: the curl transcript above showing `backend`
  alternating.
- CI green on push.

## Risks

- **Both-members assertions depend on both members being up and elected.**
  `byrequests` with equal `lbfactor` alternates strictly, so 12 fetches give
  each member 6 turns — ample margin. A member that never answers would fail
  the mix and rotation checks loudly, which is the point; the healthcheck
  `--wait` gate already stops the suite before that on a sick member.
- **Python startup vs the healthcheck.** ThreadingHTTPServer binds
  immediately and the existing `python-backend` service proves the 5 s
  `start_period` suffices; the mixed clone inherits that timing.
- **Contract drift between stacks.** The two `/messages` bodies differ in
  `message` text and key order is irrelevant to substring checks; every
  mixed-route assertion greps fields both stacks emit identically
  (`x_forwarded_proto`) or asserts the *set* of `backend` values rather than
  one body.

## Out of scope

Nginx or java members (the envsubst/`host` workaround and the slow-start
cost are recorded above if ever wanted), python `?delay=` support, mixed
failover/sticky variants, more members per balancer, and Swarm integration —
all remain queued in `docs/BACKLOG.md`.
