# More balancer members — design

Date: 2026-08-31
Source: `docs/BACKLOG.md` item 1 ("More balancer members"), originally
deferred by `docs/superpowers/specs/2026-08-27-failover-demo-design.md`.

## Goal

Grow two balancers in place, per the "named services, never scale"
convention:

1. `balancer://demo` (`balanced` profile, `24-balanced.conf`) grows from
   three to five uniform round-robin members: `node-backend-4` and
   `node-backend-5` join `node-backend-1/2/3`. No `lbfactor` weighting —
   pure growth.
2. `balancer://failover` (`failover` profile, `25-failover.conf`) changes
   shape from "1 active + 1 hot standby" to "2 active + 1 shared hot
   standby": `node-backend-primary` and new `node-backend-secondary` serve
   round-robin while healthy; `node-backend-standby` (`status=+H`) answers
   only while BOTH actives are in error state. This is the classic
   shared-standby pattern and the reason to grow the failover balancer at
   all — one spare covering a pool instead of one spare per primary.

Apache semantics note: `status=+H` puts a worker in the standby group, used
only when no non-standby worker is usable. With one active left healthy,
traffic pins to that active (no standby engagement); with both actives in
error, the standby serves.

## Non-goals

- `lbfactor`/weighted members — separate backlog-worthy demo if wanted.
- Growing any other balancer (`sticky`, `busy`, `stickyfailover`, `mixed`).
- Compose anchor refactor of `docker-compose.yml` (the "approach C" idea) —
  deliberately deferred; implementation prompt saved at
  `docs/prompts/2026-08-31-compose-anchor-refactor.md`.
- Docker Swarm / scaling — never (convention).

## Changes

### `docker-compose.yml` (18 → 21 services)

- Add `node-backend-4`, `node-backend-5` (profile `balanced`), identical to
  `node-backend-3` except `hostname:`.
- Add `node-backend-secondary` (profile `failover`) between primary and
  standby, same shape.

### `reverse-proxy/apacheconf/sites/24-balanced.conf`

- Two more `BalancerMember` lines (`node-backend-4/5`, `retry=0`).
- Header comment: "five node replicas".

### `reverse-proxy/apacheconf/sites/25-failover.conf`

- Add `BalancerMember "http://node-backend-secondary:8080" retry=5` between
  primary and standby. Both actives carry `retry=5` (bounded error window —
  the convention requirement — now applies to each active); standby keeps
  `retry=0 status=+H`.
- Header comment rewritten for the shared-standby shape.

### `.github/compose.cache.yml`

- Cache entries for the three new services (same node scope).

### `scripts/smoke.sh` (59 → 61 checks)

New helper, styled after the existing ones:

- `check_hosts_only <name> <url> <host...>` — fetches 12 times; every
  response's `host` must be one of the listed hosts and no response may
  fail. Complements `check_rotates` (which asserts spread) by asserting
  membership: the standby must never answer while actives are healthy.

`balanced` block: `check_rotates` minimum rises 2 → 5 ("all 5 of 5" —
byrequests over 5 members visits every member within 12 requests, so
requiring all 5 is safe and tighter).

`failover` block (5 → 7 checks), teaching the shared-standby story in
stages:

1. `/failover/messages` over http and https (unchanged).
2. `check_rotates` min 2 — the two actives share traffic.
3. `check_hosts_only` primary+secondary — the standby is idle while any
   active is healthy.
4. Stop `node-backend-primary`; warm the nondeterministic transition
   request through (existing pattern, `--max-time 70` discard);
   `check_host_exact node-backend-secondary` — one active down pins
   traffic to the surviving active, standby still idle.
5. Stop `node-backend-secondary` too; warm again;
   `check_host_exact node-backend-standby` — both actives down activates
   the standby.
6. `up -d --wait` both actives (the wait outlasts the 5 s retry windows);
   `check_rotates` min 2 — rotation over both actives resumes.

### Docs

- README: intro paragraph counts, architecture diagram (members 4/5,
  secondary line), service table, routes table, load-balancing and
  failover demo sections (commands reflect the staged story), tests
  section (61 checks; "fifteen services sharing the single node image"),
  configuration-model entries for 24/25, healthcheck paragraph.
- CLAUDE.md: route table rows for `balanced`/`failover`, commands comment,
  structure bullet ("twenty-one services", member lists for 24/25), smoke
  check count, "Hot standby" convention wording (both actives carry
  `retry=5`).
- `docs/BACKLOG.md`: item moves from Open to Shipped (2026-08-31); swarm
  item renumbers to 1.

## Error handling / risks

- Transition nondeterminism (DNS removal vs. 60 s block) already handled by
  the warm-request pattern; reused for both stops.
- `retry=5` on both actives: after stage 5 the primary's worker may exit
  its error window mid-test, but each election re-errors it in-request and
  defers to the standby — the existing deferral behavior the current smoke
  relies on.
- The 12-fetch helpers tolerate zero failures only in `check_hosts_only`
  and the exact-host checks; healthy-state failures would surface loudly.

## Verification

`scripts/smoke.sh balanced failover` after the change (covers both grown
balancers, the new helper, and the staged failover story); then a full
`scripts/smoke.sh` (61 checks) before calling it done.
