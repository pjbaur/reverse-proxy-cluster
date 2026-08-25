#!/bin/sh
# scripts/smoke.sh — the project's test suite.
#
# Builds the stack, starts the requested Compose profiles (default: all four),
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
  PROFILES="java nginx node python"
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

cleanup() {
  note "tearing down"
  # shellcheck disable=SC2086
  docker compose $PROFILE_ARGS down --remove-orphans --timeout 5 >/dev/null 2>&1 || true
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
    *)
      printf 'unknown profile: %s\n' "$profile" >&2
      exit 2
      ;;
  esac
done

note "summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
