# URL-Embedded Session Ids Design

**Date:** 2026-08-30
**Status:** approved by project owner
**Feature:** sticky-sessions routing by `SESSIONID` embedded in the request URL
(query-string and servlet-style path-parameter forms), demonstrated as an
extension of the existing `sticky` profile.

## Problem

The `sticky` demo pins clients only via the `SESSIONID` cookie. Backlog item
1 after the stickyfailover ship (deferred 2026-08-27 in the sticky design)
notes that `stickysession` also supports URL-embedded session ids and asks
for a small contrast demo or README section. The owner chose the fullest
option: extend the `sticky` profile with config, a backend fix, smoke
regression checks, and documentation.

## Verified Apache behavior (httpd 2.4 docs + source)

Design rests on facts read from `mod_proxy_balancer.html` and
`mod_proxy_balancer.c` (2.4.x branch), not guessed:

1. **Two URL forms.** `find_session_route` extracts the route via
   `get_path_param`, which searches the URL for `<sticky>=` bounded by
   delimiters — `?` and `&` by default, plus `;` when the balancer's
   `scolonpathdelim` is on. So `/sticky/messages?SESSIONID=x.<route>`
   (query string) works with no extra config, and
   `/sticky/messages;SESSIONID=x.<route>` (servlet-style path parameter)
   needs `scolonpathdelim=On`. Route lookup splits the value on the first
   `.`, exactly like the cookie.
2. **URL wins over cookie.** `find_session_route` tries the URL path first
   and falls back to the cookie; the docs state the request parameter's
   information takes precedence when both are present.
3. **No `stickyforce` in 2.4.** Neither the mod_proxy nor the
   mod_proxy_balancer documentation mentions it. The knob that breaks a
   pinned session with 503 when its member dies is `nofailover=On`
   (internally `sticky_force`), already demonstrated by the
   `stickyfailover` profile's strict route. The backlog's "stickyforce"
   wording is corrected by this design.
4. **The proxy never rewrites session ids into response URLs.** The docs
   are explicit: embedding is the backend's (or `mod_substitute`'s) job.
   The demo therefore shows the client-side half — a client that embeds
   the param gets pinned — plus the backend tolerance the servlet form
   requires.
5. **The proxy leaves the path parameter in the proxied request.** The
   node app receives `/messages;SESSIONID=...` verbatim; servlet
   containers strip that themselves, so the demo's backend must too or it
   404s.

## Decision record

- **Extend the `sticky` profile, no new services or profile.** The
  mechanism rides on the existing `balancer://sticky` and its two members;
  a separate demo would duplicate a balancer to show a routing-input
  difference. Rejected: README-only (leaves the servlet form undocumented
  and untested), a new `urlsticky` profile (two more containers for
  something the existing pair demonstrates).
- **Both URL forms, not just one.** The query-string form costs nothing
  and already works; the servlet form needs one `ProxySet` param plus a
  one-line backend fix, and is the canonical "URL-embedded session id"
  (jsessionid style). Showing both, plus precedence, is the complete
  answer to the backlog item.
- **Four smoke checks, including the two edge behaviors.** Pinning by
  each form, URL-over-cookie precedence, and unknown-route fallback to
  round-robin (the docs' graceful-degradation story, mirroring what the
  cookie path does). All deterministic: the URL names the member, so no
  scheduling-dependent assertion.
- **The checks name different members on purpose.** Query-form check pins
  sticky-2, servlet-form check pins sticky-1 — a stale cookie or a
  dropped `scolonpathdelim` cannot satisfy both.
- **No URL rewriting demo.** The proxy does not embed ids into responses
  and the node app generates no links to rewrite; a `mod_substitute`
  demo would be a different (and speculative) feature. Out of scope.

## Design

### Proxy config — `reverse-proxy/apacheconf/sites/26-sticky.conf`

One change inside the existing `<Proxy "balancer://sticky">` block:

```apache
ProxySet lbmethod=byrequests stickysession=SESSIONID scolonpathdelim=On
```

The file's header comment gains two lines: the URL forms
(`?SESSIONID=<id>.<route>` and `;SESSIONID=<id>.<route>`, the latter
enabled by `scolonpathdelim=On`) and the precedence rule (URL parameter
beats cookie). `scolonpathdelim` is a balancer parameter and belongs in
`ProxySet`, consistent with the worker-parameters-on-`BalancerMember`
convention.

### Backend — `backends/node/server.js`

One line. The path currently comes from
`req.url.split('?')[0]`; it becomes:

```js
const path = req.url.split('?')[0].split(';')[0];
```

with the header comment extended to explain: the proxy leaves
`;SESSIONID=...` in the proxied path, so the app strips at the semicolon
the way a servlet container would. `?delay=` parsing is untouched (it
reads the query string, which the first `split('?')` already isolated).
Behavior change surface: any request whose path contains `;` now routes
by the pre-`;` segment — no existing route or smoke check uses `;`, so
nothing regresses. `Set-Cookie` behavior is unchanged: URL-pinned
requests still receive the cookie from whichever member served them.

### Smoke — `scripts/smoke.sh`, `sticky)` case

Four new checks after the existing jar pinning checks, using existing
helpers and `STICKY_DIR` jars (jar A from the existing checks is already
pinned to one member by then):

1. `check_host_exact "sticky: query-form URL pins"` on
   `"$BASE_HTTP/sticky/messages?SESSIONID=x.node-backend-sticky-2"`
   expecting `node-backend-sticky-2`.
2. `check_host_exact "sticky: servlet-form URL pins"` on
   `"$BASE_HTTP/sticky/messages;SESSIONID=x.node-backend-sticky-1"`
   expecting `node-backend-sticky-1`.
3. `check_host_exact_jar "sticky: URL param overrides cookie"` on
   `"$BASE_HTTP/sticky/messages?SESSIONID=x.node-backend-sticky-2"` with
   a jar already holding a cookie naming sticky-1 (pinned explicitly
   before this check via the servlet-form URL so the setup is
   deterministic), expecting `node-backend-sticky-2` — the URL param
   won.
4. `check_status "sticky: unknown URL route falls back to 200"` 200 on
   `"$BASE_HTTP/sticky/messages?SESSIONID=x.no-such-route"` — an
   unknown route id is not an error; the balancer serves normally.

Suite total goes 51 → 55. (Check 4's "no pinning" nature needs no new
helper: a 200 from a sticky member is the assertion; which member
answers is deliberately unconstrained.)

### Documentation

- `README.md` sticky-sessions section gains an "URL-embedded session ids"
  subsection: curl walkthrough of both forms, the precedence result, the
  unknown-route fallback, and the `stickyforce` correction (2.4 has no
  such knob; `nofailover=On` — see the stickyfailover demo — is the
  session-break behavior). The routes table's `/sticky/messages` row and
  the sticky demo intro mention URL embedding in passing.
- `README.md` configuration model: the `26-sticky.conf` bullet gains
  `scolonpathdelim=On` and the two URL forms.
- `CLAUDE.md`: the `26-sticky.conf` structure entry mentions URL
  embedding; smoke check count 51 → 55.
- `docs/BACKLOG.md`: item 1 (URL-embedded session ids) moves to "Shipped
  from this backlog", remaining items renumber.

## Testing

`scripts/smoke.sh sticky` is the test (existing 7 sticky checks + 4 new =
11 case checks; suite total 55). The full `scripts/smoke.sh` must pass
before commit per repo convention. Determinism: checks 1–3 assert named
members chosen by the URL itself; check 4 asserts only a 200.

## Out of scope

Response-side URL rewriting (`mod_substitute`/`mod_sed` link rewriting),
`nofailover` interaction with URL-pinned sessions (the stickyfailover
demo already covers the knob), and URL embedding on other profiles'
balancers (the mechanism is identical wherever `stickysession` is set).
