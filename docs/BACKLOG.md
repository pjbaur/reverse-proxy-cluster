# Product Backlog

Deferred and future work for the reverse-proxy-cluster demo. Items here come
from the "Out of scope" / deferred sections of the design specs in
`docs/superpowers/specs/` — when a design defers something, it lands in this
file. Nothing here is scheduled; the order below roughly reflects teaching
value, not commitment.

## Open items

### 1. Swarm integration

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

- **More balancer members** — deferred 2026-08-27 in the failover design,
  shipped 2026-08-31: `balancer://demo` grew to five members
  (`node-backend-4/5`, `24-balanced.conf`) and `balancer://failover` to
  two actives plus a shared hot standby (`node-backend-secondary`,
  `25-failover.conf`). See
  `docs/superpowers/specs/2026-08-31-more-balancer-members-design.md`.
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
- **URL-embedded session ids** — deferred 2026-08-27 in the sticky
  design, shipped 2026-08-30 as an extension of the `sticky` profile
  (`scolonpathdelim=On` in `26-sticky.conf`, `;`-path stripping in the
  node backend; query and servlet forms, URL-over-cookie precedence).
- **A non-node backend inside a balancer** — deferred 2026-08-25 in the
  balancer design (re-deferred by the failover and sticky designs), shipped
  2026-08-30 as the `mixed` profile (`29-mixed.conf`,
  `node-backend-mixed-1` + `python-backend-mixed-1` in one `byrequests`
  round-robin).
