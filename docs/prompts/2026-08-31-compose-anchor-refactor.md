# Prompt: dedupe docker-compose.yml with YAML anchors (backlog "approach C")

Use this prompt with a fresh agent session in the repo root. It implements
the Compose anchor refactor that was deliberately left out of the
"more balancer members" change (approach A, shipped 2026-08-31 — that change
grew the stack to 21 services and made the repetition worse, which is the
reason this refactor is worth doing on its own).

---

## Prompt

You are working in `reverse-proxy-cluster`, a Docker Compose demo repo.
Refactor `docker-compose.yml` to remove service-definition duplication with
YAML anchors and merge keys. Behavior must not change at all — this is a
pure structural refactor, verified by rendering, not by re-designing.

### Background

The file defines 21 services: `reverse-proxy`, four single backends
(java/nginx/node/python), five `balanced` replicas, three `failover`
members (primary/secondary/standby), two `sticky`, two `busy`, two
`stickyfailover`, and two `mixed` members. Sixteen of them are node-backend
copies that differ from each other in only three keys at most:
`hostname:`, `profiles:`, and (sticky/stickyfailover services only) an
`environment: {ROUTE: ...}` map. The rest of each block — `build`,
`restart: unless-stopped`, `networks: [proxy-net]`, and the busybox-wget
healthcheck — is byte-identical across all node services. The python
services (`python-backend`, `python-backend-mixed-1`) share their own
identical block shape.

The project convention (CLAUDE.md, "Adding a backend") documents the
copy-paste block explicitly; after this refactor that section must be
updated to document the anchor pattern instead, and the smoke suite is the
safety net.

### Goal

Introduce top-level extension anchors (Compose supports YAML merge keys in
this file position) so each repeated service shrinks to only its differing
keys. Target shape:

```yaml
x-node-backend: &node-backend
  build: ./backends/node
  restart: unless-stopped
  networks:
    - proxy-net
  healthcheck:
    test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/messages"]
    interval: 10s
    timeout: 3s
    retries: 3
    start_period: 5s

services:
  node-backend-1:
    <<: *node-backend
    hostname: node-backend-1
    profiles: ["balanced"]
```

Do the same for the python services (`&python-backend`, healthcheck probes
port 8080 on 127.0.0.1) and consider whether `java-backend`, `nginx-backend`
and `reverse-proxy` are worth anchoring — they each differ more (published
ports, longer `start_period`, different probe paths), so leave them inline
unless an anchor genuinely removes duplication without obscuring their
differences. Bias: fewer anchors, clearer file.

### Hard constraints

1. **Rendered config must be identical.** Before editing, capture
   `docker compose --profile java --profile nginx --profile node --profile python --profile balanced --profile failover --profile sticky --profile busy --profile stickyfailover --profile mixed config > /tmp/before.yml`
   and after editing the same command into `/tmp/after.yml`; they must be
   identical (`diff /tmp/before.yml /tmp/after.yml` empty). `docker compose
   config` resolves anchors, so this proves behavior is unchanged. If the
   diff is non-empty, every difference is a regression you introduced — fix
   it, do not rationalize it.
2. **No service may be renamed, reordered, or re-profiled.** Service order
   in the file stays as-is; the anchor blocks go at the top, after the
   `name:` line.
3. **Shallow-merge semantics:** `<<:` replaces whole nested maps. The
   sticky/stickyfailover services need their full `environment:` map in the
   service (there is nothing to partially merge — their env is one key), and
   any service that later needs a second env var must restate the whole map
   or get its own anchor. Keep that in mind and do not invent per-key merge
   tricks; YAML merge keys do not deep-merge.
4. `.github/compose.cache.yml` is untouched by this refactor. It merges
   `build.cache_from` into services by name after anchor resolution, so it
   keeps working — confirm with
   `docker compose -f docker-compose.yml -f .github/compose.cache.yml --profile balanced config`
   that the cache keys still appear on the balanced services.
5. Preserve the file's existing comment style and 2-space indent. No
   reformatting of untouched services.

### Steps

1. Capture `/tmp/before.yml` as in constraint 1.
2. Add the anchor blocks; convert the node and python services.
3. Capture `/tmp/after.yml`; diff must be empty (constraint 1) and the
   cache-override render must still show `cache_from` (constraint 4).
4. Update CLAUDE.md's "Adding a backend" step 2 to show the anchored form
   (`<<: *node-backend` plus the three differing keys) instead of the full
   copy-paste block, and note where the anchors live.
5. Update the "Structure" bullet in CLAUDE.md that describes
   `docker-compose.yml` if it mentions the duplication pattern.
6. Update README.md only if it describes the service blocks' shape (the
   service table and healthcheck paragraph describe services, not the YAML
   layout — likely no README change is needed; do not force one).
7. Run `scripts/smoke.sh balanced failover` (exercises anchored services in
   both profiles plus the proxy). If Docker is unavailable, state plainly
   that the render-diff was the only verification and smoke must be run
   before merge.
8. Do not commit. Report the diff summary and the verification results.

### Out of scope

- No new services, no anchor for `reverse-proxy`'s published ports, no
  Compose `extends:` (the long-form cross-file mechanism — anchors are the
  in-file equivalent and enough here), no changes to healthcheck values,
  no reordering, no renaming.
