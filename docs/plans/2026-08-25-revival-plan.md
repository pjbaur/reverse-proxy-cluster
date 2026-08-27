# Project Revival & Modernization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Revive the broken 2023 reverse-proxy demo into a modern, modular, self-verifying multi-backend showcase: pinned images, four swappable backends via Compose profiles, TLS, healthchecks, CI, and rewritten docs.

**Architecture:** One Apache httpd reverse proxy (always on) fronting four independent backend implementations (Java/Spring Boot 3, nginx static, Node, Python), each selectable via Docker Compose profiles, routed by URL path prefix. A generated smoke-test script acts as the executable test suite; GitHub Actions runs build + smoke on every push.

**Tech Stack:** Docker Compose v2 (profiles), Apache httpd 2.4.68 (pinned), Spring Boot 3.5 / Java 21 (multi-stage Maven build on eclipse-temurin), nginx alpine, node:22-alpine (zero-dep), python:3.12-alpine (zero-dep), openssl for dev certs, GitHub Actions.

## Context

The repository is a 2023 Baeldung-tutorial follow-along (Apache proxy in front of a Spring Boot jar), committed to git for the first time on 2026-08-25 and reviewed critically the same day (docs/REVIEW.md). It cannot run: the backend base image `openjdk:8-jdk-alpine` was removed from Docker Hub, the backend exists only as a 29 MB opaque jar (no source), `httpd:latest` is unpinned, and there are no tests, healthchecks, TLS, or CI. The user decided (2026-08-25) to revive rather than archive, with these locked choices:

1. **Modularity = Docker Compose profiles** — four backends (`java`, `nginx`, `node`, `python`); proxy always runs; profiles composable. No load balancer.
2. **Java backend source recreated in-repo** — Spring Boot 3.5.x (latest patch 3.5.16, verified on Maven Central), Java 21; old jar deleted from working tree once replaced.
3. **Modernization = core fixes + ops (healthchecks, restart policies, smoke script, CI) + TLS (self-signed dev certs, HTTPS listener, X-Forwarded-* headers) + observability (mod_status, protected).**
4. **Docs rewritten** (README.md, CLAUDE.md) to match; docs/REVIEW.md kept as historical record.

Verified at plan time (2026-08-25): Docker 29.7.2 + Compose v5.4.0 (`--profile`, `--wait`, `cache_from/to` all supported); real Docker Hub tags `httpd:2.4.68-alpine`, `eclipse-temurin:21-jre-alpine`, `maven:3.9-eclipse-temurin-21`, `nginx:1.30-alpine`, `node:22-alpine`, `python:3.12-alpine`; host has JDK 21, Maven 3.9, OpenSSL 1.1.1+ (`req -addext` works).

## Global Constraints

- Base images pinned: proxy patch-pinned (`httpd:2.4.68-alpine`), backends major-pinned. No `latest` anywhere.
- No obsolete Compose `version:` key.
- Apache 2.4-only syntax (no `Order`/`Allow from`/`access_compat`), load only required modules.
- Generated certs never committed (`reverse-proxy/certs/` gitignored).
- Every task ends runnable, verified, and committed (conventional commits).
- All smoke assertions via plain `curl http://localhost:8080/...` — no `/etc/hosts` edits, works in CI.
- No new runtime dependencies for node/python backends (built-in modules only).
- Global rules: never commit secrets, no history rewrites, docs updated with behavior changes.

## Key Design Decisions

- **D1 Routing:** path prefixes (`/java/`, `/nginx/`, `/node/`, `/python/`) as *server-config-level* `ProxyPass` directives, one file per backend in `apacheconf/sites/` (numeric prefixes fix include order). The **only VirtualHost in the entire config is `<VirtualHost *:443>`** (TLS); port 80 is served by the main server config directly, and server-level config is inherited into the `:443` vhost — identical behavior on both listeners, zero duplication, no name-vhost/hosts-file trap. Every `ProxyPass` carries `retry=0` (default 60 s worker error-state would flake dev restarts).
- **D2 Static content:** nginx backend serves its own baked-in `html/`; proxy keeps a small landing page at `/` (its healthcheck target and a smoke assertion). Old `htmlfiles/` + `testlocal.conf` deleted.
- **D3 Zero-dep backends:** node uses `node:http` only; python uses stdlib `http.server` only. No package managers in CI, minimal supply chain.
- **D4 Backend contract:** `GET /messages` → 200 compact JSON with `backend`, `message`, `host`, and received `x_forwarded_proto`/`x_forwarded_port`/`x_forwarded_for` — echoes make the header plumbing observable; smoke asserts `"x_forwarded_proto":"https"` behind TLS. Python must use `json.dumps(..., separators=(",", ":"))` (default spaces would break substring assertions). nginx serves a *static* `messages` file (deliberate contrast; `host` static there).
- **D5 Ports:** publish only the proxy — `8080:80`, `8443:443`. Backends have no `ports:` (debug via `docker compose exec ... wget`). In-container: 8080 for java/node/python, 80 for nginx.
- **D6 Healthchecks in docker-compose.yml** (single source of truth), all busybox `wget` (ships in every alpine image). Java `start_period: 20s` (JVM boot); others 5s. No actuator — `/messages` is the health endpoint. Fallback if a base ever drops busybox: ubuntu `eclipse-temurin:21-jre` + `curl -fsS`.
- **D7 TLS:** `scripts/gen-dev-certs.sh` → 3650-day self-signed cert (`CN=localhost`, SAN `DNS:localhost,IP:127.0.0.1`) into gitignored `certs/`, **baked into the image at build time** (matches project's "config baked in, rebuild to change" convention; avoids crash-loop on missing bind mount). TLS 1.2/1.3 only, shmcb session cache. No HTTP→HTTPS redirect (dev demo; smoke contract uses plain HTTP) — redirect recipe left as comment.
- **D8 X-Forwarded:** mod_proxy_http sets For/Host/Server; we add `RequestHeader set X-Forwarded-Proto "expr=%{REQUEST_SCHEME}"` and `X-Forwarded-Port "expr=%{SERVER_PORT}"` per request (correct on both listeners).
- **D9 mod_status:** `ExtendedStatus On`, `/server-status` `Require ip` loopback + RFC1918 (covers Docker bridge gateway that published-port traffic arrives from; excludes public). No balancer-manager (no balancer by decision).
- **D10 Module trim:** 42 → 14 modules. Keep: `mpm_event`, `authz_core`, `authz_host`, `unixd`, `log_config`, `mime`, `dir`, `headers`, `reqtimeout`, `status`, `proxy`, `proxy_http` (+ `socache_shmcb`, `ssl` for TLS).
- **D11 CI:** one job (matrix would rebuild shared proxy 4×); GHA layer cache via CI-only override `.github/compose.cache.yml` (keeps user compose portable — `type=gha` fails outside GitHub). Java tests run inside image build (no `-DskipTests`).
- **D12 Java:** `com.example:java-message-server:1.0.0`, package `com.example.messages`, Boot 3.5.16 parent, `java.version=21`, `spring-boot-starter-web` + test. Baeldung provenance dropped. `@WebMvcTest` controller tests. Multi-stage: `maven:3.9-eclipse-temurin-21` (dep layer + m2 cache mount) → `eclipse-temurin:21-jre-alpine`, non-root `spring` user.
- **D13 Deletions:** `app-server/` (incl. jar), `start-command.txt`, `testlocal.conf`, `htmlfiles/`; network `spring-cloud-network` → `proxy-net`; top-level compose `name: reverse-proxy-cluster`.
- **D14 Ordering:** each commit builds+runs. Proxy image first (standalone verify, no compose), then compose rewrite (healthcheck `wget` needs the alpine image), TLS, backends one at a time (source+routing per task), smoke suite, CI, docs, sweep.

## Target Architecture

```
              host :8080 (http) ──┐   host :8443 (https, self-signed) ──┐
                                    ▼                                     ▼
                        reverse-proxy (httpd:2.4.68-alpine, always on)
                        /                     landing page
                        /server-status        mod_status, private ranges only
                        /java/   ──► java-backend:8080    profile java    Spring Boot 3.5 / Java 21
                        /nginx/  ──► nginx-backend:80     profile nginx   static content
                        /node/   ──► node-backend:8080    profile node    node:http, zero-dependency
                        /python/ ──► python-backend:8080  profile python  stdlib http.server
                        └──────────── bridge network proxy-net ───────────┘
```

Final tree:

```
reverse-proxy-cluster/
├── docker-compose.yml
├── .github/
│   ├── workflows/ci.yml
│   └── compose.cache.yml
├── scripts/
│   ├── gen-dev-certs.sh
│   └── smoke.sh
├── backends/
│   ├── java/          # Dockerfile, pom.xml, .dockerignore, src/{main,test}/...
│   ├── nginx/         # Dockerfile, nginx.conf, html/{index.html,messages}
│   ├── node/          # Dockerfile, server.js
│   └── python/        # Dockerfile, server.py
├── reverse-proxy/
│   ├── Dockerfile
│   ├── httpd.conf
│   ├── apacheconf/
│   │   ├── htdocs/index.html
│   │   └── sites/{00-server-status,10-proxy,20-java,21-nginx,22-node,23-python,90-ssl}.conf
│   └── certs/         # gitignored; written by scripts/gen-dev-certs.sh
├── README.md
├── CLAUDE.md          # AGENTS.md symlink keeps pointing here
├── .gitignore
└── docs/
    ├── REVIEW.md      # historical, unchanged
    └── plans/2026-08-25-revival-plan.md   # copy of this plan (Task 13)
```

---

## Task 1 — Modernize proxy image (pin, trim, 2.4-only, status, forward headers)

**Files:** Modify `reverse-proxy/Dockerfile`, `reverse-proxy/httpd.conf`; Create `reverse-proxy/apacheconf/sites/00-server-status.conf`, `10-proxy.conf`, `reverse-proxy/apacheconf/htdocs/index.html`; Delete `reverse-proxy/apacheconf/sites/testlocal.conf`, `reverse-proxy/apacheconf/htmlfiles/`.

- [x] **Step 1: Rewrite `reverse-proxy/Dockerfile`**

```dockerfile
# Patch-pinned: the proxy is the demo's subject — reproducibility matters most here.
FROM httpd:2.4.68-alpine

# Trimmed base config (2.4-only syntax, 14 modules), lands in the stock path.
COPY httpd.conf /usr/local/apache2/conf/httpd.conf

# Per-topic config: status policy, forward headers, one file per backend route,
# TLS vhost. COPY creates conf/sites/ automatically.
COPY apacheconf/sites/ /usr/local/apache2/conf/sites/

# Landing page served from DocumentRoot.
COPY apacheconf/htdocs/ /usr/local/apache2/htdocs/

EXPOSE 80

# httpd-foreground is the stock entrypoint of the httpd image (httpd -D FOREGROUND).
CMD ["httpd-foreground"]
```

No package installs (busybox wget covers healthchecks on alpine).

- [x] **Step 2: Replace `reverse-proxy/httpd.conf`**

```apache
# reverse-proxy-cluster — base Apache configuration.
# Trimmed to what this stack uses: static landing page, reverse proxying
# (mod_proxy_http), TLS, mod_status. Apache 2.4-only syntax.

ServerRoot "/usr/local/apache2"

Listen 80

# --- modules (12 here; TLS adds socache_shmcb + ssl in 90-ssl.conf) -----
LoadModule mpm_event_module modules/mod_mpm_event.so
# `Require` framework + the `ip` provider used to protect /server-status
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule authz_host_module modules/mod_authz_host.so
# worker process identity
LoadModule unixd_module modules/mod_unixd.so
# logging
LoadModule log_config_module modules/mod_log_config.so
# content types + DirectoryIndex
LoadModule mime_module modules/mod_mime.so
LoadModule dir_module modules/mod_dir.so
# X-Forwarded-* request headers
LoadModule headers_module modules/mod_headers.so
# slow-client (slowloris) header timeouts — stock default, worth keeping
LoadModule reqtimeout_module modules/mod_reqtimeout.so
# /server-status
LoadModule status_module modules/mod_status.so
# reverse proxy
LoadModule proxy_module modules/mod_proxy.so
LoadModule proxy_http_module modules/mod_proxy_http.so

# --- server identity --------------------------------------------------------
ServerName localhost
User daemon
Group daemon

# --- static landing page ----------------------------------------------------
DocumentRoot "/usr/local/apache2/htdocs"
<Directory />
    AllowOverride none
    Require all denied
</Directory>
<Directory "/usr/local/apache2/htdocs">
    Options -Indexes
    Require all granted
</Directory>
<Files ".ht*">
    Require all denied
</Files>

# --- logging: container-native stdout/stderr ---------------------------------
ErrorLog "/proc/self/fd/2"
LogLevel warn
LogFormat "%h %l %u %t \"%r\" %>s %b" common
LogFormat "%h %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\"" combined
CustomLog "/proc/self/fd/1" combined

TypesConfig conf/mime.types
DirectoryIndex index.html

# --- everything else lives in conf/sites/*.conf -------------------------------
# Numeric prefixes fix include order. Everything except 90-ssl.conf is
# server-level config: it serves port 80 directly and is inherited by the
# *:443 vhost, so routing/headers/status behave identically on both listeners.
IncludeOptional conf/sites/*.conf
```

- [x] **Step 3: Create `reverse-proxy/apacheconf/sites/00-server-status.conf`**

```apache
# /server-status — mod_status diagnostics.
ExtendedStatus On

<Location "/server-status">
    SetHandler server-status
    # Dev-demo policy: loopback + RFC 1918 only. Published-port traffic arrives
    # from the Docker bridge gateway (172.16-31.x), so host curl and CI work;
    # public source addresses are refused. No balancer-manager by design.
    Require ip 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
</Location>
```

- [x] **Step 4: Create `reverse-proxy/apacheconf/sites/10-proxy.conf`**

```apache
# Reverse-proxy behaviour shared by every backend route (server level:
# applies to port 80 directly, inherited by the *:443 vhost in 90-ssl.conf).

# Off is the default — stated explicitly because ProxyRequests On would turn
# this server into a FORWARD proxy (open relay). Never enable it here.
ProxyRequests Off

# mod_proxy_http already adds X-Forwarded-For, X-Forwarded-Host and
# X-Forwarded-Server. It does NOT set Proto/Port, so derive them per request.
RequestHeader set X-Forwarded-Proto "expr=%{REQUEST_SCHEME}"
RequestHeader set X-Forwarded-Port  "expr=%{SERVER_PORT}"

# The per-backend ProxyPass directives in 2x-*.conf carry retry=0: the default
# 60s worker error-state after one failed connect would flake dev workflows.
```

- [x] **Step 5: Create `reverse-proxy/apacheconf/htdocs/index.html`**

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>reverse-proxy-cluster</title>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 42rem; margin: 3rem auto; padding: 0 1rem; line-height: 1.5; }
    code { background: #f1f1f1; padding: .1rem .3rem; border-radius: .25rem; }
    li { margin: .25rem 0; }
  </style>
</head>
<body>
  <h1>reverse-proxy-cluster</h1>
  <p>Apache httpd reverse proxy running. Backends are enabled with Compose
     profiles — a route below only answers once its profile is up:</p>
  <ul>
    <li><code>GET /java/messages</code> — Spring Boot 3.5 / Java 21 (<code>--profile java</code>)</li>
    <li><code>GET /nginx/</code> and <code>GET /nginx/messages</code> — static nginx (<code>--profile nginx</code>)</li>
    <li><code>GET /node/messages</code> — Node.js (<code>--profile node</code>)</li>
    <li><code>GET /python/messages</code> — Python (<code>--profile python</code>)</li>
  </ul>
  <p>Also served: this page over HTTPS at <code>https://localhost:8443/</code>
     (self-signed dev cert) and <code>GET /server-status</code> (private ranges only).</p>
</body>
</html>
```

- [x] **Step 6: Delete old confs** — `git rm reverse-proxy/apacheconf/sites/testlocal.conf && git rm -r reverse-proxy/apacheconf/htmlfiles`

- [x] **Step 7: Verify standalone (old compose untouched)**

```sh
docker build -t proxy-tmp reverse-proxy/
docker run -d --rm --name proxy-tmp -p 8080:80 proxy-tmp
sleep 1
docker exec proxy-tmp httpd -t                                          # → Syntax OK
curl -fsS http://localhost:8080/ | grep -q "reverse-proxy-cluster" && echo LANDING-OK
curl -fsS http://localhost:8080/server-status | grep -q "Apache Server Status" && echo STATUS-OK
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/nope      # → 404
docker exec proxy-tmp httpd -M | grep -c "proxy_module\|proxy_http_module"    # → 2
docker exec proxy-tmp httpd -M | grep -c "ssl_module\|access_compat"          # → 0
docker rm -f proxy-tmp
```

- [x] **Step 8: Commit** (includes untracked `docs/REVIEW.md` as historical record)

```
feat(proxy): pin httpd 2.4.68-alpine, trim modules, 2.4-only config
```

---

## Task 2 — Compose rewrite: profiles skeleton, delete dead backend, rename network

**Files:** Replace `docker-compose.yml`; Delete `app-server/`, `start-command.txt`.

- [x] **Step 1: Replace `docker-compose.yml`** (proxy-only at this commit; backends appended in Tasks 5–8)

```yaml
name: reverse-proxy-cluster

services:
  reverse-proxy:
    build: ./reverse-proxy
    container_name: reverse-proxy
    restart: unless-stopped
    ports:
      - "8080:80"
    networks:
      - proxy-net
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost/"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s

networks:
  proxy-net:
    driver: bridge
```

- [x] **Step 2: Delete** — `git rm -r app-server && git rm start-command.txt`

- [x] **Step 3: Verify**

```sh
docker compose config -q                              # valid, no version-key warning
docker compose up -d --build --wait
docker compose ps                                     # reverse-proxy Up (healthy)
curl -fsS http://localhost:8080/ | grep -q "reverse-proxy-cluster" && echo LANDING-OK
curl -fsS http://localhost:8080/server-status >/dev/null && echo STATUS-OK
docker compose down
```

- [x] **Step 4: Commit**

```
feat(compose)!: profile-based stack with proxy-only base
```

Body: drop obsolete version key; `spring-cloud-network` → `proxy-net`; restart policy + healthcheck; delete `app-server/` (dead base image, sourceless jar) and stale `start-command.txt`.

---

## Task 3 — TLS: cert script, HTTPS listener on 8443

**Files:** Create `scripts/gen-dev-certs.sh`; Modify `.gitignore`, `reverse-proxy/httpd.conf`, `reverse-proxy/Dockerfile`, `docker-compose.yml`; Create `reverse-proxy/apacheconf/sites/90-ssl.conf`.

- [x] **Step 1: Create `scripts/gen-dev-certs.sh`** (+ `chmod +x`)

```sh
#!/bin/sh
# Generate the self-signed certificate for the proxy's HTTPS listener.
# Requires OpenSSL >= 1.1.1 (uses `req -addext` for the SAN).
# Output is gitignored; the proxy Dockerfile bakes it into the image, so after
# regenerating run: docker compose build reverse-proxy
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERT_DIR="$ROOT/reverse-proxy/certs"

mkdir -p "$CERT_DIR"

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$CERT_DIR/server.key" \
  -out "$CERT_DIR/server.crt" \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

chmod 600 "$CERT_DIR/server.key"

echo "Wrote $CERT_DIR/server.crt"
echo "Wrote $CERT_DIR/server.key"
```

- [x] **Step 2: Append to `.gitignore`**

```
reverse-proxy/certs/
```

- [x] **Step 3: Edit `reverse-proxy/httpd.conf`** — after `Listen 80` add `Listen 443`; add to module block:

```apache
Listen 443
# TLS (socache_shmcb backs the SSL session cache)
LoadModule socache_shmcb_module modules/mod_socache_shmcb.so
LoadModule ssl_module modules/mod_ssl.so
```

- [x] **Step 4: Create `reverse-proxy/apacheconf/sites/90-ssl.conf`**

```apache
# HTTPS listener. Self-signed dev certificate generated by
# scripts/gen-dev-certs.sh and baked in at build time.
# This is the ONLY VirtualHost in the config: everything defined at server
# level (DocumentRoot, the 2x-*.conf ProxyPass routes, the X-Forwarded-*
# headers, the /server-status policy) is inherited here, so both listeners
# serve identical behaviour.
<VirtualHost *:443>
    ServerName localhost
    SSLEngine on
    SSLCertificateFile    "/usr/local/apache2/conf/certs/server.crt"
    SSLCertificateKeyFile "/usr/local/apache2/conf/certs/server.key"
    SSLProtocol -all +TLSv1.2 +TLSv1.3
    SSLSessionCache        "shmcb:/usr/local/apache2/logs/ssl_scache(512000)"
    SSLSessionCacheTimeout 300
    ErrorLog  "/proc/self/fd/2"
    CustomLog "/proc/self/fd/1" combined
</VirtualHost>

# HTTP -> HTTPS redirect is deliberately NOT enabled: plain HTTP on 8080 is
# part of the smoke tests and the proxy healthcheck. To force TLS instead,
# add mod_alias back to httpd.conf and create:
#   <VirtualHost *:80>
#       ServerName localhost
#       Redirect permanent / https://localhost:8443/
#   </VirtualHost>
```

- [x] **Step 5: Edit `reverse-proxy/Dockerfile`** — add before `EXPOSE`; change `EXPOSE 80` → `EXPOSE 80 443`

```dockerfile
# Dev TLS certificate from scripts/gen-dev-certs.sh (gitignored).
# If this COPY fails with "not found": run scripts/gen-dev-certs.sh, rebuild.
COPY certs/server.crt certs/server.key /usr/local/apache2/conf/certs/
```

- [x] **Step 6: Edit `docker-compose.yml`** proxy ports:

```yaml
    ports:
      - "8080:80"
      - "8443:443"
```

- [x] **Step 7: Verify**

```sh
scripts/gen-dev-certs.sh
git status --porcelain | grep certs                   # no output (gitignored)
openssl x509 -in reverse-proxy/certs/server.crt -noout -subject -ext subjectAltName
docker compose up -d --build --wait
curl -fsS  http://localhost:8080/ | grep -q reverse-proxy-cluster && echo HTTP-OK
curl -kfsS https://localhost:8443/ | grep -q reverse-proxy-cluster && echo HTTPS-OK
curl -kfsS https://localhost:8443/server-status | grep -q "Apache Server Status" && echo STATUS-TLS-OK
curl -s -o /dev/null -w '%{http_code}\n' -k https://localhost:8443/nope    # → 404
echo | openssl s_client -connect localhost:8443 2>/dev/null | grep -E "Protocol|Cipher" | head -2
   # → TLSv1.3 (or 1.2); never 1.0/1.1
docker compose down
```

- [x] **Step 8: Commit**

```
feat(proxy): self-signed HTTPS listener published on 8443
```

---

## Task 4 — Java backend: source + multi-stage build (verified standalone)

**Files (all new):** `backends/java/pom.xml`, `src/main/java/com/example/messages/MessageServerApplication.java`, `MessageController.java`, `src/main/resources/application.properties`, `src/test/java/com/example/messages/MessageControllerTest.java`, `Dockerfile`.

- [x] **Step 1: Write failing test** `backends/java/src/test/java/com/example/messages/MessageControllerTest.java`

```java
package com.example.messages;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.test.web.servlet.MockMvc;

import static org.hamcrest.Matchers.containsString;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(MessageController.class)
class MessageControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void messagesIdentifiesBackend() throws Exception {
        mockMvc.perform(get("/messages"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.backend").value("java"))
                .andExpect(jsonPath("$.message").value(containsString("Spring Boot")));
    }

    @Test
    void messagesEchoesForwardHeadersWhenPresent() throws Exception {
        mockMvc.perform(get("/messages")
                        .header("X-Forwarded-Proto", "https")
                        .header("X-Forwarded-Port", "443"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.x_forwarded_proto").value("https"))
                .andExpect(jsonPath("$.x_forwarded_port").value("443"));
    }

    @Test
    void unknownPathIs404() throws Exception {
        mockMvc.perform(get("/nope")).andExpect(status().isNotFound());
    }
}
```

- [x] **Step 2: Write `backends/java/pom.xml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>

  <parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.5.16</version>
    <relativePath/>
  </parent>

  <groupId>com.example</groupId>
  <artifactId>java-message-server</artifactId>
  <version>1.0.0</version>
  <name>java-message-server</name>
  <description>Spring Boot backend for the reverse-proxy-cluster demo</description>

  <properties>
    <java.version>21</java.version>
  </properties>

  <dependencies>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-web</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-test</artifactId>
      <scope>test</scope>
    </dependency>
  </dependencies>

  <build>
    <plugins>
      <plugin>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-maven-plugin</artifactId>
      </plugin>
    </plugins>
  </build>
</project>
```

- [x] **Step 3: Write main classes.** `MessageServerApplication.java`:

```java
package com.example.messages;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class MessageServerApplication {

    public static void main(String[] args) {
        SpringApplication.run(MessageServerApplication.class, args);
    }
}
```

`MessageController.java`:

```java
package com.example.messages;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.LinkedHashMap;
import java.util.Map;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;

/**
 * The single endpoint mirrored by every backend in this demo:
 * GET /messages -> JSON identifying who answered and which X-Forwarded-*
 * headers arrived (they prove the reverse proxy is setting them).
 */
@RestController
public class MessageController {

    @GetMapping("/messages")
    public Map<String, Object> messages(
            @RequestHeader(value = "X-Forwarded-Proto", required = false) String forwardedProto,
            @RequestHeader(value = "X-Forwarded-Port", required = false) String forwardedPort,
            @RequestHeader(value = "X-Forwarded-For", required = false) String forwardedFor) {

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("backend", "java");
        body.put("message", "Hello from Spring Boot");
        body.put("host", hostname());
        body.put("x_forwarded_proto", forwardedProto);
        body.put("x_forwarded_port", forwardedPort);
        body.put("x_forwarded_for", forwardedFor);
        return body;
    }

    private static String hostname() {
        try {
            return InetAddress.getLocalHost().getHostName();
        } catch (UnknownHostException e) {
            return "unknown";
        }
    }
}
```

`application.properties`:

```properties
# 8080 is the in-container convention shared by the non-nginx backends.
server.port=8080
```

- [x] **Step 4: Write `backends/java/Dockerfile`**

```dockerfile
# ---- build: compile and TEST (tests run on every image build) ---------------
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build

# Dependencies as their own layer: unchanged pom.xml => cached, no re-download.
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 mvn -q dependency:go-offline

COPY src ./src
# No -DskipTests: building the image IS the verification.
RUN --mount=type=cache,target=/root/.m2 mvn -q package

# ---- runtime: JRE only, non-root --------------------------------------------
FROM eclipse-temurin:21-jre-alpine
RUN addgroup -S spring && adduser -S spring -G spring
WORKDIR /app
USER spring
COPY --from=build /build/target/java-message-server-1.0.0.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
```

- [x] **Step 5: Verify** — run test before writing impl? Controller is Step 3; run tests now (host has JDK 21 + Maven):

```sh
cd backends/java && mvn -q test && cd ../..          # 3 tests pass
docker build -t java-backend-tmp backends/java/      # maven build + tests inside
docker run -d --rm --name java-tmp -p 18080:8080 java-backend-tmp
sleep 8
curl -fsS http://localhost:18080/messages            # {"backend":"java",...,"x_forwarded_proto":null,...}
curl -fsS -H "X-Forwarded-Proto: https" http://localhost:18080/messages | grep -q '"x_forwarded_proto":"https"' && echo HEADER-OK
docker exec java-tmp id                              # uid=spring — non-root
docker exec java-tmp wget -q -O /dev/null http://localhost:8080/messages && echo WGET-OK
docker rm -f java-tmp
```

If `WGET-OK` fails: switch runtime base to `eclipse-temurin:21-jre` + `curl -fsS` healthcheck in Task 5 (D6 fallback).

- [x] **Step 6: Commit**

```
feat(java): Spring Boot 3.5 message backend source with multi-stage build
```

---

## Task 5 — Wire java into compose and routing (`/java/`)

**Files:** Modify `docker-compose.yml`; Create `reverse-proxy/apacheconf/sites/20-java.conf`.

- [x] **Step 1: Append service to `docker-compose.yml`**

```yaml
  java-backend:
    build: ./backends/java
    profiles: ["java"]
    restart: unless-stopped
    networks:
      - proxy-net
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost:8080/messages"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 20s
```

- [x] **Step 2: Create `reverse-proxy/apacheconf/sites/20-java.conf`**

```apache
# /java/... -> java-backend (Spring Boot 3.5, Compose profile "java").
# Server-level directives: apply on :80 and are inherited by the :443 vhost.
# retry=0: retry every request even if a previous one found the backend down.
# Backend down/unstarted profile => 502 on this prefix only.
ProxyPass        /java/ http://java-backend:8080/ retry=0
ProxyPassReverse /java/ http://java-backend:8080/
```

- [x] **Step 3: Verify**

```sh
docker compose --profile java up -d --build --wait
docker compose ps                                    # both services (healthy)
curl -fsS http://localhost:8080/java/messages | grep -q '"backend":"java"' && echo ROUTE-OK
curl -fsS http://localhost:8080/java/messages | grep -q '"x_forwarded_proto":"http"' && echo PROTO-HTTP-OK
curl -kfsS https://localhost:8443/java/messages | grep -q '"x_forwarded_proto":"https"' && echo PROTO-HTTPS-OK
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/node/messages   # → 502 (profile not up)
docker compose down --remove-orphans
```

- [x] **Step 4: Commit**

```
feat(java): serve /java/ via profile java
```

---

## Task 6 — nginx backend (`/nginx/`, static)

**Files:** Create `backends/nginx/{Dockerfile,nginx.conf,html/index.html,html/messages}`; Modify `docker-compose.yml`; Create `reverse-proxy/apacheconf/sites/21-nginx.conf`.

- [x] **Step 1: `backends/nginx/Dockerfile`**

```dockerfile
FROM nginx:1.30-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY html/ /usr/share/nginx/html/
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

- [x] **Step 2: `backends/nginx/nginx.conf`**

```nginx
# Static backend served by its own nginx container (profile "nginx").
# `messages` is an extension-less file, so the JSON content type must be set
# explicitly; everything else is ordinary static file serving.
server {
    listen 80;
    server_name nginx-backend;

    root /usr/share/nginx/html;
    index index.html;

    location = /messages {
        default_type application/json;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
```

- [x] **Step 3: `backends/nginx/html/index.html`** (relative href resolves to `/nginx/messages` through the proxy)

```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>nginx backend</title></head>
<body style="font-family: system-ui, sans-serif; max-width: 40rem; margin: 3rem auto; line-height: 1.5;">
  <h1>nginx backend</h1>
  <p>Static content served by the <code>nginx-backend</code> container behind
     the Apache reverse proxy at <code>/nginx/</code>.</p>
  <p>JSON endpoint: <a href="messages">messages</a> (a static file, served as
     <code>application/json</code>).</p>
</body>
</html>
```

- [x] **Step 4: `backends/nginx/html/messages`** (extension-less static JSON; `host` static by design — the contrast this backend demonstrates)

```json
{"backend":"nginx","message":"Hello from nginx static content","host":"nginx-backend","note":"static file - host is not dynamic here"}
```

- [x] **Step 5: Append service to `docker-compose.yml`**

```yaml
  nginx-backend:
    build: ./backends/nginx
    profiles: ["nginx"]
    restart: unless-stopped
    networks:
      - proxy-net
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost/"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s
```

- [x] **Step 6: Create `reverse-proxy/apacheconf/sites/21-nginx.conf`**

```apache
# /nginx/... -> nginx-backend (static content, Compose profile "nginx").
ProxyPass        /nginx/ http://nginx-backend:80/ retry=0
ProxyPassReverse /nginx/ http://nginx-backend:80/
```

- [x] **Step 7: Verify**

```sh
docker compose --profile nginx up -d --build --wait
curl -fsS http://localhost:8080/nginx/ | grep -q "nginx backend" && echo STATIC-OK
curl -fsS http://localhost:8080/nginx/messages | grep -q '"backend":"nginx"' && echo JSON-OK
curl -fsSI http://localhost:8080/nginx/messages | grep -i "content-type: application/json" && echo CTYPE-OK
curl -kfsS https://localhost:8443/nginx/ | grep -q "nginx backend" && echo TLS-OK
docker compose down --remove-orphans
```

- [x] **Step 8: Commit**

```
feat(nginx): static nginx backend served at /nginx/ via profile nginx
```

---

## Task 7 — node backend (`/node/`, zero-dependency)

**Files:** Create `backends/node/{server.js,Dockerfile}`; Modify `docker-compose.yml`; Create `reverse-proxy/apacheconf/sites/22-node.conf`.

- [x] **Step 1: `backends/node/server.js`**

```js
// Zero-dependency Node backend (profile "node"): node's built-in http module,
// no package.json, no package manager, nothing to install.
'use strict';

const http = require('node:http');
const os = require('node:os');

const PORT = 8080;

const server = http.createServer((req, res) => {
  const path = req.url.split('?')[0];

  if (req.method === 'GET' && path === '/messages') {
    const body = JSON.stringify({
      backend: 'node',
      message: 'Hello from Node.js',
      host: os.hostname(),
      x_forwarded_proto: req.headers['x-forwarded-proto'] || null,
      x_forwarded_port: req.headers['x-forwarded-port'] || null,
      x_forwarded_for: req.headers['x-forwarded-for'] || null,
    });
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(body);
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'not found', path }));
});

server.listen(PORT, () => {
  console.log(`node backend listening on :${PORT}`);
});
```

- [x] **Step 2: `backends/node/Dockerfile`**

```dockerfile
FROM node:22-alpine
WORKDIR /app
COPY server.js .
USER node
EXPOSE 8080
CMD ["node", "server.js"]
```

- [x] **Step 3: Append service to `docker-compose.yml`**

```yaml
  node-backend:
    build: ./backends/node
    profiles: ["node"]
    restart: unless-stopped
    networks:
      - proxy-net
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost:8080/messages"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s
```

- [x] **Step 4: Create `reverse-proxy/apacheconf/sites/22-node.conf`**

```apache
# /node/... -> node-backend (zero-dependency Node, Compose profile "node").
ProxyPass        /node/ http://node-backend:8080/ retry=0
ProxyPassReverse /node/ http://node-backend:8080/
```

- [x] **Step 5: Verify**

```sh
node --check backends/node/server.js               # syntax OK
docker compose --profile node up -d --build --wait
curl -fsS http://localhost:8080/node/messages | grep -q '"backend":"node"' && echo ROUTE-OK
curl -fsS http://localhost:8080/node/messages | grep -q '"x_forwarded_proto":"http"' && echo PROTO-HTTP-OK
curl -kfsS https://localhost:8443/node/messages | grep -q '"x_forwarded_proto":"https"' && echo PROTO-HTTPS-OK
docker compose exec node-backend id                # uid=1000(node)
docker compose down --remove-orphans
```

- [x] **Step 6: Commit**

```
feat(node): zero-dependency node backend served at /node/ via profile node
```

---

## Task 8 — python backend (`/python/`, stdlib only)

**Files:** Create `backends/python/{server.py,Dockerfile}`; Modify `docker-compose.yml`; Create `reverse-proxy/apacheconf/sites/23-python.conf`.

- [x] **Step 1: `backends/python/server.py`**

```python
#!/usr/bin/env python3
"""Zero-dependency Python backend (profile "python"): stdlib http.server only.

separators=(",", ":") keeps the JSON compact so smoke assertions that match
substrings like "backend":"python" behave the same across all backends.
"""

import json
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8080


class MessageHandler(BaseHTTPRequestHandler):
    server_version = "PythonBackend/1.0"

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/messages":
            body = json.dumps(
                {
                    "backend": "python",
                    "message": "Hello from Python",
                    "host": socket.gethostname(),
                    "x_forwarded_proto": self.headers.get("X-Forwarded-Proto"),
                    "x_forwarded_port": self.headers.get("X-Forwarded-Port"),
                    "x_forwarded_for": self.headers.get("X-Forwarded-For"),
                },
                separators=(",", ":"),
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        body = json.dumps({"error": "not found", "path": path},
                          separators=(",", ":")).encode("utf-8")
        self.send_response(404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        # container-native: everything on stdout, unbuffered (python -u)
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), MessageHandler).serve_forever()
```

- [x] **Step 2: `backends/python/Dockerfile`**

```dockerfile
FROM python:3.12-alpine
WORKDIR /app
COPY server.py .
USER nobody
EXPOSE 8080
CMD ["python3", "-u", "server.py"]
```

- [x] **Step 3: Append service to `docker-compose.yml`**

```yaml
  python-backend:
    build: ./backends/python
    profiles: ["python"]
    restart: unless-stopped
    networks:
      - proxy-net
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost:8080/messages"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s
```

- [x] **Step 4: Create `reverse-proxy/apacheconf/sites/23-python.conf`**

```apache
# /python/... -> python-backend (stdlib-only Python, Compose profile "python").
ProxyPass        /python/ http://python-backend:8080/ retry=0
ProxyPassReverse /python/ http://python-backend:8080/
```

- [x] **Step 5: Verify**

```sh
python3 -m py_compile backends/python/server.py && echo SYNTAX-OK
docker compose --profile python up -d --build --wait
curl -fsS http://localhost:8080/python/messages | grep -q '"backend":"python"' && echo ROUTE-OK
curl -fsS http://localhost:8080/python/messages | grep -q '"x_forwarded_proto":"http"' && echo PROTO-HTTP-OK
curl -kfsS https://localhost:8443/python/messages | grep -q '"x_forwarded_proto":"https"' && echo PROTO-HTTPS-OK
docker compose down --remove-orphans
```

- [x] **Step 6: Commit**

```
feat(python): stdlib-only python backend served at /python/ via profile python
```

---

## Task 9 — `scripts/smoke.sh` — the project's test suite

**Files:** Create `scripts/smoke.sh` (+ `chmod +x`).

- [x] **Step 1: Write `scripts/smoke.sh`**

```sh
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
```

- [x] **Step 2: Verify green path**

```sh
sh -n scripts/smoke.sh && echo SYNTAX-OK
scripts/smoke.sh        # every line "ok"; summary: 17 passed, 0 failed (4 proxy + 4 java + 3 nginx + 3 node + 3 python); exit 0
docker compose ps -a    # empty — teardown ran
scripts/smoke.sh java   # 8 checks ok (4 proxy + 4 java)
```

- [x] **Step 3: Verify failure path** (break one expectation, confirm non-zero exit and full run, revert)

```sh
sed -i '' 's/"backend":"java"/"backend":"JAVA"/' scripts/smoke.sh
scripts/smoke.sh java; echo "exit=$?"   # java checks FAIL, exit=1
git checkout -- scripts/smoke.sh
```

- [x] **Step 4: Commit**

```
test: add scripts/smoke.sh end-to-end suite
```

---

## Task 10 — CI: GitHub Actions build + smoke with layer cache

**Files:** Create `.github/compose.cache.yml`, `.github/workflows/ci.yml`.

- [x] **Step 1: `.github/compose.cache.yml`** (CI-only override; `type=gha` fails outside GitHub, so it is never merged locally)

```yaml
# CI-only Compose override: import/export build cache via GitHub Actions'
# cache backend. Only .github/workflows/ci.yml merges this file.
services:
  reverse-proxy:
    build:
      context: ./reverse-proxy
      cache_from: ["type=gha"]
      cache_to: ["type=gha,mode=max"]
  java-backend:
    build:
      context: ./backends/java
      cache_from: ["type=gha"]
      cache_to: ["type=gha,mode=max"]
  nginx-backend:
    build:
      context: ./backends/nginx
      cache_from: ["type=gha"]
      cache_to: ["type=gha,mode=max"]
  node-backend:
    build:
      context: ./backends/node
      cache_from: ["type=gha"]
      cache_to: ["type=gha,mode=max"]
  python-backend:
    build:
      context: ./backends/python
      cache_from: ["type=gha"]
      cache_to: ["type=gha,mode=max"]
```

- [x] **Step 2: `.github/workflows/ci.yml`**

```yaml
name: ci

on:
  push:
    branches: [master]
  pull_request:

jobs:
  smoke:
    name: build + smoke test
    runs-on: ubuntu-latest
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4

      - uses: docker/setup-buildx-action@v3

      - name: Generate dev certificate
        run: scripts/gen-dev-certs.sh

      - name: Build all profiles with layer cache
        run: |
          docker compose \
            -f docker-compose.yml \
            -f .github/compose.cache.yml \
            --profile java --profile nginx --profile node --profile python \
            build

      - name: Smoke test (full stack)
        run: scripts/smoke.sh
```

- [x] **Step 3: Verify locally (real run happens on push)**

```sh
docker compose -f docker-compose.yml -f .github/compose.cache.yml config -q && echo OVERRIDE-MERGES-OK
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml')); yaml.safe_load(open('.github/compose.cache.yml')); print('YAML-OK')"
git ls-files -s scripts/ | awk '{print $1}'   # 100755 for both scripts (executable bit committed)
```

- [x] **Step 4: Commit**

```
ci: build all profiles and run smoke.sh on push and PR
```

---

## Task 11 — Docs rewrite: README.md + CLAUDE.md

**Files:** Replace `README.md`, `CLAUDE.md` (AGENTS.md symlink unchanged).

Content requirements (write full docs from the architecture as built; the design doc contains complete drafts — architecture diagram above, route table below):

- **README.md sections:** title + one-paragraph description; architecture diagram; Quickstart (`scripts/gen-dev-certs.sh`, `docker compose --profile java up -d --build`, curls); Routes table (`GET /` landing, `/java/messages`, `/nginx/` + `/nginx/messages`, `/node/messages`, `/python/messages`, `/server-status`); note that every backend echoes `X-Forwarded-*` headers; Tests section (`scripts/smoke.sh` full/subset, CI description, Java tests inside image build); Configuration model (httpd.conf trimmed/2.4-only, `apacheconf/sites/` alphabetical includes with numeric prefixes, config+certs baked into image — rebuild after edits, TLS self-signed + no-redirect-by-design + recipe location, pinning policy proxy-patch/backends-major, healthchecks in compose); Troubleshooting (cert missing → gen script; port in use → change compose + smoke BASE_*; 502 → profile not running; cert warning → `-k`); pointer to `docs/REVIEW.md` as the historical motivation.
- **CLAUDE.md sections:** project summary (proxy + four profile backends, prefixes, published ports only); Commands (gen certs, up with profiles, smoke full/subset, logs, down); Structure map (compose, httpd.conf + sites, backends contract, scripts, docs/REVIEW.md do-not-update); Conventions (rebuild-not-reload; adding-a-backend recipe: `backends/<name>/` + compose service block with profile + wget healthcheck + `sites/2x-<name>.conf` with `ProxyPass /<name>/ http://<name>-backend:<port>/ retry=0`, no vhost edits; 2.4 syntax only; pinning policy; conventional commits; run smoke before committing).

- [x] **Step 1: Replace `README.md`** with content covering the sections above.
- [x] **Step 2: Replace `CLAUDE.md`** with content covering the sections above.
- [x] **Step 3: Verify** — every documented command spot-checked (`docker compose config --services` matches doc; `readlink AGENTS.md` → `CLAUDE.md`); `scripts/smoke.sh java` still green.
- [x] **Step 4: Commit**

```
docs: rewrite README and CLAUDE.md for the profile architecture
```

---

## Task 12 — Final sweep: dockerignore, dangling-reference guard, full-stack verification

**Files:** Create `backends/java/.dockerignore` (`target/` only — note: `reverse-proxy/` must NOT ignore `certs/`).

- [x] **Step 1: Create `backends/java/.dockerignore`**

```
target/
```

- [x] **Step 2: Dangling-reference guard**

```sh
grep -rn "app-server\|testlocal\|spring-cloud-network\|httpd:latest\|openjdk\|baeldung" \
  --exclude-dir=.git --exclude-dir=docs . || echo NO-DANGLING-REFS
```

Expected `NO-DANGLING-REFS` (docs/REVIEW.md excluded — frozen historical record).

- [x] **Step 3: Full-stack verification (all profiles simultaneously)**

```sh
docker compose --profile java --profile nginx --profile node --profile python up -d --build --wait
docker compose ps    # five services, all "Up (healthy)"
for u in / /server-status /java/messages /nginx/ /nginx/messages /node/messages /python/messages; do
  printf '%-24s %s\n' "$u" "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080$u)"
done   # every line 200
for u in / /java/messages /nginx/ /node/messages /python/messages; do
  printf 'https %-18s %s\n' "$u" "$(curl -sk -o /dev/null -w '%{http_code}' https://localhost:8443$u)"
done   # every line 200
scripts/smoke.sh     # full suite green
docker compose --profile java --profile nginx --profile node --profile python down --remove-orphans
```

- [x] **Step 4: Commit**

```
chore: java build-context ignore, final full-stack verification
```

---

## Task 13 — Store this plan in the repository

**Files:** Create `docs/plans/2026-08-25-revival-plan.md`.

- [x] **Step 1:** Copy this plan document into `docs/plans/2026-08-25-revival-plan.md` (verbatim, including design decisions).
- [x] **Step 2: Commit**

```
docs: add revival implementation plan
```

---

## Verification (end-to-end, after all tasks)

1. `scripts/smoke.sh` — full suite, expect `summary: 17 passed, 0 failed`, exit 0, clean teardown.
2. `docker compose --profile java --profile nginx --profile node --profile python ps` — five healthy services.
3. Push to GitHub; CI run green (first run cold-cache, second faster via GHA cache).
4. `git log --oneline` — 13 conventional commits, each leaving a buildable state.

## Risks & Fallbacks

- **busybox wget on temurin alpine** — verified in Task 4 (`docker exec java-tmp wget ...`); fallback D6: ubuntu `eclipse-temurin:21-jre` + curl healthcheck.
- **Server-level inheritance into `:443`** — standard vhost merge; verified directly in Task 3 (`https /server-status` 200) and per-backend over TLS. If ever broken: move `2x-*.conf` includes inside the vhost — one-line change.
- **`openssl req -addext`** — needs ≥ 1.1.1 (host 1.1.1k, GH runners 3.x). Documented in script.
- **`up --wait` flakes** — `--wait-timeout 180`, java `start_period: 20s`.
- **Self-signed cert** — every https check uses `-k`; documented in README.

## Self-Review Notes

- Spec coverage: revive (Tasks 1–2), correct (1–3, 12), document (11, 13), improve/modernize (3–10), modular backends (2, 5–8 + conventions in CLAUDE.md). All four locked decisions implemented.
- No placeholders: every step has real file content or exact commands.
- Consistency: backend JSON contract keys (`backend`, `message`, `host`, `x_forwarded_*`) identical across Tasks 4/6/7/8 and asserted in Task 9; compose service names match ProxyPass targets (`java-backend`, `nginx-backend`, `node-backend`, `python-backend`); smoke counts: 17 all-profiles, 8 java-only.
