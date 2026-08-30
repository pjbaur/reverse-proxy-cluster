# Product Backlog

Deferred and future work for the reverse-proxy-cluster demo. Items here come
from the "Out of scope" / deferred sections of the design specs in
`docs/superpowers/specs/` — when a design defers something, it lands in this
file. Nothing here is scheduled; the order below roughly reflects teaching
value, not commitment.

## Open items

### 1. URL-embedded session ids

`stickysession` also supports `;SESSIONID=...` URL embedding
(`stickyforce`, URL rewriting) in addition to the cookie path the demo uses.
A small contrast demo or README section would show it.

Source: `docs/superpowers/specs/2026-08-27-sticky-sessions-design.md`
(out of scope).

### 2. A non-node backend inside a balancer

All five balancer demos (`balanced`, `failover`, `sticky`, `busy`,
`stickyfailover`) ride on the zero-dependency node backend. Putting a
second stack (nginx or python) behind `mod_proxy_balancer` would show
the balancer is backend-agnostic.
Touches: new balancer member services, one `BalancerMember` line each, and
possibly the `host`-field contract if the backend cannot echo container
hostname the way the node app does.

Sources: `2026-08-25-balancer-demo-design.md`,
`2026-08-27-failover-demo-design.md`,
`2026-08-27-sticky-sessions-design.md` (all list "non-node backends" as out
of scope).

### 3. More balancer members

Grow `balancer://demo` beyond three members (or the failover pair beyond
two). Per the conventions in CLAUDE.md this means new named services plus
`BalancerMember` lines — never `docker compose scale` — so the work is
mostly Compose plumbing plus smoke-check updates.

Source: `docs/superpowers/specs/2026-08-27-failover-demo-design.md`
(out of scope).

### 4. Swarm integration

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

- **`bybusyness` contrast** — deferred 2026-08-25 in the balancer design,
  shipped 2026-08-29 as the `busy` profile (`27-busy.conf`,
  `node-backend-busy-1/2`, `?delay=` in the node backend).
- **Sticky sessions / session affinity** — deferred 2026-08-25 in the
  balancer design, shipped 2026-08-27 as the `sticky` profile
  (`26-sticky.conf`, `node-backend-sticky-1/2`).
- **Hot-standby failover** — deferred 2026-08-25 in the balancer design,
  shipped 2026-08-27 as the `failover` profile (`25-failover.conf`,
  `node-backend-primary/standby`).
- **Sticky sessions interacting with failover members** — deferred
  2026-08-27 in the sticky design, shipped 2026-08-30 as the
  `stickyfailover` profile (`28-stickyfailover.conf`,
  `node-backend-sf-primary/standby`; also demonstrates `nofailover=On`).
