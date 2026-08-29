# Product Backlog

Deferred and future work for the reverse-proxy-cluster demo. Items here come
from the "Out of scope" / deferred sections of the design specs in
`docs/superpowers/specs/` — when a design defers something, it lands in this
file. Nothing here is scheduled; the order below roughly reflects teaching
value, not commitment.

## Open items

### 1. `bybusyness` load-balancing contrast demo

Queued the longest — named as deferred in three straight design specs
(balanced, failover, sticky). A second balancer route using
`lbmethod=bybusyness` would contrast with the existing `byrequests`
round-robin in `/balanced/`, showing how Apache shifts traffic away from busy
members. Requires one new `LoadModule` line
(`mod_lbmethod_bybusyness`) and a new numbered site config; the existing
conventions for balancer members (named services, explicit
`BalancerMember` lines) apply unchanged.

Source: `docs/superpowers/specs/2026-08-25-balancer-demo-design.md` (out of
scope), re-confirmed in the 2026-08-27 failover and sticky designs.

### 2. Sticky sessions interacting with failover members

Combine `balancer://sticky`-style session affinity with a `status=+H` hot
standby: does pinning survive primary failure, and where does the session
land during recovery? The two demos currently exercise these behaviors in
isolation.

Source: `docs/superpowers/specs/2026-08-27-sticky-sessions-design.md`
(out of scope).

### 3. URL-embedded session ids

`stickysession` also supports `;SESSIONID=...` URL embedding
(`stickyforce`, URL rewriting) in addition to the cookie path the demo uses.
A small contrast demo or README section would show it.

Source: `docs/superpowers/specs/2026-08-27-sticky-sessions-design.md`
(out of scope).

### 4. A non-node backend inside a balancer

All three balancer demos (`balanced`, `failover`, `sticky`) ride on the
zero-dependency node backend. Putting a second stack (nginx or python)
behind `mod_proxy_balancer` would show the balancer is backend-agnostic.
Touches: new balancer member services, one `BalancerMember` line each, and
possibly the `host`-field contract if the backend cannot echo container
hostname the way the node app does.

Sources: `2026-08-25-balancer-demo-design.md`,
`2026-08-27-failover-demo-design.md`,
`2026-08-27-sticky-sessions-design.md` (all list "non-node backends" as out
of scope).

### 5. More balancer members

Grow `balancer://demo` beyond three members (or the failover pair beyond
two). Per the conventions in CLAUDE.md this means new named services plus
`BalancerMember` lines — never `docker compose scale` — so the work is
mostly Compose plumbing plus smoke-check updates.

Source: `docs/superpowers/specs/2026-08-27-failover-demo-design.md`
(out of scope).

### 6. Swarm integration

Running the demo under Docker Swarm (multiple hosts, `docker stack deploy`)
instead of single-host Compose. Largest scope item here; would change the
"named services" constraint (Swarm DNS behaves differently) and likely needs
its own design spec.

Source: `docs/superpowers/specs/2026-08-25-balancer-demo-design.md`
(out of scope).

## Deliberate non-goals

Not backlog — decided against, recorded so they are not re-litigated:

- **HTTP to HTTPS redirect.** Dev demo; the smoke contract uses plain HTTP
  on 8080. The recipe is left as a comment in the SSL site config. See
  `docs/plans/2026-08-25-revival-plan.md` (decision D7).
- **Updating `docs/REVIEW.md`.** Frozen historical record by convention.

## Shipped from this backlog

Deferred items that were later implemented — kept for context:

- **Sticky sessions / session affinity** — deferred 2026-08-25 in the
  balancer design, shipped 2026-08-27 as the `sticky` profile
  (`26-sticky.conf`, `node-backend-sticky-1/2`).
- **Hot-standby failover** — deferred 2026-08-25 in the balancer design,
  shipped 2026-08-27 as the `failover` profile (`25-failover.conf`,
  `node-backend-primary/standby`).
