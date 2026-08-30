#!/bin/sh
# scripts/smoke.sh — the project's test suite.
#
# Builds the stack, starts the requested Compose profiles (default: all eight),
# waits until every container reports healthy, then exercises every route and
# tears the stack down again. All checks run even if one fails (so a single
# failure doesn't hide others); any failure exits non-zero.
#
# Usage:
#   scripts/smoke.sh                 # all profiles
#   scripts/smoke.sh java node       # any subset
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ "$#" -gt 0 ]; then
  PROFILES="$*"
else
  PROFILES="java nginx node python balanced failover sticky busy stickyfailover"
fi

PROFILE_ARGS=""
for profile in $PROFILES; do
  PROFILE_ARGS="$PROFILE_ARGS --profile $profile"
done

PASS=0
FAIL=0

note()   { printf '==> %s\n' "$1"; }
ok()     { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
failed() { printf 'FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

# check <name> <url> <expected substring> [extra curl args...]
check() {
  name="$1"; url="$2"; want="$3"; shift 3
  if body="$(curl -fsS "$@" "$url" 2>/dev/null)" && printf '%s' "$body" | grep -qF "$want"; then
    ok "$name"
  else
    failed "$name - wanted '$want' from $url"
  fi
}

# check_status <name> <expected-status> <url> [extra curl args...]
check_status() {
  name="$1"; want="$2"; url="$3"; shift 3
  got="$(curl -s -o /dev/null -w '%{http_code}' "$@" "$url")"
  if [ "$got" = "$want" ]; then
    ok "$name"
  else
    failed "$name - got HTTP $got, wanted $want"
  fi
}

# check_rotates <name> <url> <min-distinct> — fetches 12 times, counts
# distinct "host" values; round-robin over 3 members must spread >= 2.
check_rotates() {
  name="$1"; url="$2"; min="$3"
  hosts=""
  i=0
  while [ "$i" -lt 12 ]; do
    h="$(curl -fsS "$url" 2>/dev/null | sed -n 's/.*"host":"\([^"]*\)".*/\1/p')" || h=""
    hosts="$hosts $h"
    i=$((i + 1))
  done
  distinct="$(for h in $hosts; do [ -n "$h" ] && echo "$h"; done | sort -u | grep -c .)" || true
  if [ "${distinct:-0}" -ge "$min" ]; then
    ok "$name"
  else
    failed "$name - only $distinct distinct hosts (wanted >= $min) from $url"
  fi
}

# check_host_exact <name> <url> <expected-host> — fetches 6 times; every
# response's "host" must equal expected-host. Failover is deterministic
# (unlike rotation), so any deviation is a failure.
check_host_exact() {
  name="$1"; url="$2"; want="$3"
  i=0; bad=0; empty=0
  while [ "$i" -lt 6 ]; do
    h="$(curl -fsS "$url" 2>/dev/null | sed -n 's/.*"host":"\([^"]*\)".*/\1/p')" || h=""
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

# check_host_constant <name> <url> <jar> — fetches 6 times through a curl
# cookie jar; every response's "host" must be the same value (stickiness
# pins a client to one member; which member is not deterministic under
# byrequests, so constancy is the assertion, not identity).
check_host_constant() {
  name="$1"; url="$2"; jar="$3"
  first=""
  i=0; bad=0; empty=0
  while [ "$i" -lt 6 ]; do
    h="$(curl -fsS -b "$jar" -c "$jar" "$url" 2>/dev/null | sed -n 's/.*"host":"\([^"]*\)".*/\1/p')" || h=""
    if [ -z "$h" ]; then
      empty=$((empty + 1))
    elif [ -z "$first" ]; then
      first="$h"
    elif [ "$h" != "$first" ]; then
      bad=$((bad + 1))
    fi
    i=$((i + 1))
  done
  if [ "$bad" -eq 0 ] && [ "$empty" -eq 0 ]; then
    ok "$name"
  else
    failed "$name - $bad drifted, $empty failed responses (wanted one constant host) from $url"
  fi
}

# check_avoids_busy <name> <url> — holds one ?delay=5000 request in flight
# against the url, then fetches 4 fast ones while it runs; every fast
# response's "host" must be identical and differ from the slow request's
# host (bybusyness skips the member with the active request; byrequests
# would alternate members, failing constancy).
check_avoids_busy() {
  name="$1"; url="$2"
  body_file="$(mktemp)"
  hosts=""
  curl -fsS "$url?delay=5000" -o "$body_file" 2>/dev/null &
  slow_pid=$!
  sleep 0.6
  i=0; empty=0
  while [ "$i" -lt 4 ]; do
    h="$(curl -fsS "$url" 2>/dev/null | sed -n 's/.*"host":"\([^"]*\)".*/\1/p')" || h=""
    if [ -n "$h" ]; then
      hosts="$hosts $h"
    else
      empty=$((empty + 1))
    fi
    i=$((i + 1))
  done
  wait "$slow_pid" 2>/dev/null || true
  slow_host="$(sed -n 's/.*"host":"\([^"]*\)".*/\1/p' "$body_file")"
  rm -f "$body_file"
  bad=0; first=""
  for h in $hosts; do
    if [ -z "$first" ]; then
      first="$h"
    elif [ "$h" != "$first" ]; then
      bad=$((bad + 1))
    fi
  done
  if [ "$first" = "$slow_host" ]; then
    bad=$((bad + 1))
  fi
  if [ "$bad" -eq 0 ] && [ "$empty" -eq 0 ] && [ -n "$first" ] && [ -n "$slow_host" ]; then
    ok "$name"
  else
    failed "$name - fast hosts '$hosts' not constant on the other member (slow: '$slow_host', empty: $empty) from $url"
  fi
}

cleanup() {
  note "tearing down"
  # shellcheck disable=SC2086
  docker compose $PROFILE_ARGS down --remove-orphans --timeout 5 >/dev/null 2>&1 || true
  if [ -n "${STICKY_DIR:-}" ]; then
    rm -rf "$STICKY_DIR"
  fi
  if [ -n "${body_file:-}" ]; then
    rm -f "$body_file"
  fi
}
trap cleanup EXIT INT TERM

# The proxy image bakes the dev certificate in at build time.
if [ ! -f reverse-proxy/certs/server.crt ]; then
  note "no dev certificate found - generating one"
  scripts/gen-dev-certs.sh
fi

note "building and starting profiles: $PROFILES"
# shellcheck disable=SC2086
docker compose $PROFILE_ARGS up -d --build --wait --wait-timeout 180

BASE_HTTP="http://localhost:8080"
BASE_HTTPS="https://localhost:8443"
STICKY_DIR="$(mktemp -d)"   # cookie jars for the sticky pinning checks

# --- the proxy itself, independent of any backend ---------------------------
check        "landing page over http"      "$BASE_HTTP/"               "reverse-proxy-cluster"
check        "landing page over https"     "$BASE_HTTPS/"              "reverse-proxy-cluster" -k
check_status "unknown path returns 404"    404 "$BASE_HTTP/does-not-exist"
check        "server-status serves status" "$BASE_HTTP/server-status"  "Apache Server Status"

# --- per-profile routes ------------------------------------------------------
for profile in $PROFILES; do
  case $profile in
    java)
      check "java: /java/messages"                     "$BASE_HTTP/java/messages"   '"backend":"java"'
      check "java: X-Forwarded-Proto=http"             "$BASE_HTTP/java/messages"   '"x_forwarded_proto":"http"'
      check "java: /java/messages over https"          "$BASE_HTTPS/java/messages"  '"backend":"java"' -k
      check "java: X-Forwarded-Proto=https behind TLS" "$BASE_HTTPS/java/messages"  '"x_forwarded_proto":"https"' -k
      ;;
    nginx)
      check "nginx: static page at /nginx/"            "$BASE_HTTP/nginx/"          "nginx backend"
      check "nginx: JSON at /nginx/messages"           "$BASE_HTTP/nginx/messages"  '"backend":"nginx"'
      check "nginx: /nginx/ over https"                "$BASE_HTTPS/nginx/"         "nginx backend" -k
      ;;
    node)
      check "node: /node/messages"                     "$BASE_HTTP/node/messages"   '"backend":"node"'
      check "node: X-Forwarded-Proto=http"             "$BASE_HTTP/node/messages"   '"x_forwarded_proto":"http"'
      check "node: X-Forwarded-Proto=https behind TLS" "$BASE_HTTPS/node/messages"  '"x_forwarded_proto":"https"' -k
      ;;
    python)
      check "python: /python/messages"                     "$BASE_HTTP/python/messages"  '"backend":"python"'
      check "python: X-Forwarded-Proto=http"               "$BASE_HTTP/python/messages"  '"x_forwarded_proto":"http"'
      check "python: X-Forwarded-Proto=https behind TLS"   "$BASE_HTTPS/python/messages" '"x_forwarded_proto":"https"' -k
      ;;
    balanced)
      check "balanced: /balanced/messages"                "$BASE_HTTP/balanced/messages"   '"backend":"node"'
      check "balanced: X-Forwarded-Proto=http"            "$BASE_HTTP/balanced/messages"   '"x_forwarded_proto":"http"'
      check "balanced: /balanced/messages over https"     "$BASE_HTTPS/balanced/messages"  '"backend":"node"' -k
      check_rotates "balanced: host rotation (>=2 of 3)"  "$BASE_HTTP/balanced/messages"   2
      check "balanced: balancer-manager dashboard"        "$BASE_HTTP/balancer-manager"    "Load Balancer Manager"
      ;;
    failover)
      check "failover: /failover/messages"            "$BASE_HTTP/failover/messages"   '"backend":"node"'
      check "failover: /failover/messages over https" "$BASE_HTTPS/failover/messages"  '"backend":"node"' -k
      check_host_exact "failover: primary serves all"  "$BASE_HTTP/failover/messages"  node-backend-primary
      # shellcheck disable=SC2086
      if docker compose $PROFILE_ARGS stop node-backend-primary >/dev/null 2>&1; then
        # The first request after the stop is the transition itself and is
        # nondeterministic: compose removes the stopped container's DNS
        # entry, so the balancer either eats a DNS lookup failure (AH00898,
        # 500 to the client, no in-request deferral) or blocks on the dead
        # address until the ~60 s Timeout before retrying on the standby.
        # Either outcome puts the primary worker into error state; the
        # standby defers reliably from the *second* request. Warm the
        # transition through, then assert the steady state.
        curl -fsS --max-time 70 "$BASE_HTTP/failover/messages" >/dev/null 2>&1 || true
        check_host_exact "failover: standby takes over" "$BASE_HTTP/failover/messages" node-backend-standby
        # --wait outlasts the primary's 5 s retry window (the healthcheck
        # interval alone is 10 s), so the primary is re-elected right away.
        # Keep it that way if the healthcheck interval is ever lowered.
        # shellcheck disable=SC2086
        if docker compose $PROFILE_ARGS up -d --wait --wait-timeout 60 node-backend-primary >/dev/null 2>&1; then
          check_host_exact "failover: primary recovers" "$BASE_HTTP/failover/messages" node-backend-primary
        else
          failed "failover: primary did not come back healthy after restart"
        fi
      else
        failed "failover: could not stop node-backend-primary"
      fi
      ;;
    sticky)
      check "sticky: /sticky/messages"                "$BASE_HTTP/sticky/messages"    '"backend":"node"'
      check "sticky: /sticky/messages over https"     "$BASE_HTTPS/sticky/messages"   '"backend":"node"' -k
      check_rotates       "sticky: rotation without cookie" "$BASE_HTTP/sticky/messages" 2
      check_host_constant "sticky: jar A pinned"      "$BASE_HTTP/sticky/messages"    "$STICKY_DIR/a.jar"
      check_host_constant "sticky: jar B pinned"      "$BASE_HTTP/sticky/messages"    "$STICKY_DIR/b.jar"
      ;;
    busy)
      check "busy: /busy/messages"                  "$BASE_HTTP/busy/messages"              '"backend":"node"'
      check "busy: X-Forwarded-Proto=http"          "$BASE_HTTP/busy/messages"              '"x_forwarded_proto":"http"'
      check "busy: /busy/messages over https"       "$BASE_HTTPS/busy/messages"             '"backend":"node"' -k
      check "busy: delay parameter honored"         "$BASE_HTTP/busy/messages?delay=500"    '"backend":"node"'
      check_avoids_busy "busy: bybusyness avoids the busy member" "$BASE_HTTP/busy/messages"
      ;;
    stickyfailover)
      check "stickyfailover: /stickyfailover/messages"               "$BASE_HTTP/stickyfailover/messages"              '"backend":"node"'
      check "stickyfailover: X-Forwarded-Proto=http"                 "$BASE_HTTP/stickyfailover/messages"              '"x_forwarded_proto":"http"'
      check "stickyfailover: /stickyfailover/messages over https"    "$BASE_HTTPS/stickyfailover/messages"             '"backend":"node"' -k
      check_host_exact "stickyfailover: unpinned always primary"     "$BASE_HTTP/stickyfailover/messages"              node-backend-sf-primary
      check "stickyfailover: strict /stickyfailover-strict/messages" "$BASE_HTTP/stickyfailover-strict/messages"       '"backend":"node"'
      ;;
    *)
      printf 'unknown profile: %s\n' "$profile" >&2
      exit 2
      ;;
  esac
done

note "summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
