# Critical Project Review — reverse-proxy-cluster

**Date:** 2026-08-25
**Method:** Repository-only forensic review with runtime verification (built images, ran the proxy container, exercised endpoints, inspected the jar).
**Audience:** Project owner.

Evidence labels: **[FACT]** directly observed (file content or runtime output). **[INFER]** reasonable conclusion from evidence. **[SPEC]** speculation, flagged as such.

---

## 1. Executive Summary

This repository is a **dormant learning experiment, now broken by ecosystem drift**. It contains a Docker Compose pair — an Apache `httpd` reverse proxy and a Spring Boot "message server" — built in February 2023 from a Baeldung tutorial (jar manifest: `Start-Class: com.baeldung.spring.cloud.config.docker.DockerServer`, `Built-By: paulbaur`, 2023-02-20), committed to git for the first time on 2026-08-25.

**The project cannot run as committed.** The backend image base `openjdk:8-jdk-alpine` was removed from Docker Hub; the app-server build fails, and with it the whole Compose stack. Verified live: `docker compose up --build` → `failed to resolve source metadata for docker.io/library/openjdk:8-jdk-alpine: not found`.

Overall maturity: **prototype / tutorial-follow-along, below MVP**. Not production, not maintained, and currently non-functional.

**Top 3 strengths**
1. Correct architectural skeleton: proxy and backend as separate services on a private bridge network, service-name DNS for routing — the standard, idiomatic pattern **[FACT]**.
2. Config-as-files intent: base `httpd.conf` plus an `IncludeOptional conf/sites/*.conf` directory for virtual hosts — extensible by design, comments explain each step **[FACT]**.
3. Container-native logging: both the base config and the vhost log to `/dev/stdout` **[FACT]**.

**Top 3 risks**
1. **Fatal build breakage** from an unpinned, since-deleted base image; nothing in the repo runs end-to-end today **[FACT]**.
2. **The backend is a 29 MB opaque binary** — no source, no build files. It cannot be patched, upgraded, or audited beyond `unzip` **[FACT]**.
3. **Non-reproducibility everywhere else too**: `httpd:latest` floats (currently resolves to 2.4.68), no image digests, no lockfile, no CI **[FACT]**.

**Confidence:** high on all build/runtime findings (directly reproduced); medium on intent inference (tutorial provenance is from the manifest and package names, not stated anywhere).

---

## 2. Repository Overview & First Impressions

```
.
├── docker-compose.yml          # 2 services, 1 bridge network
├── start-command.txt           # pre-Compose manual docker run notes
├── README.md, CLAUDE.md, AGENTS.md, .gitignore   # added 2026-08-25
├── docs/REVIEW.md              # this document
├── reverse-proxy/
│   ├── Dockerfile              # httpd:latest + ping/curl + custom conf
│   ├── httpd.conf              # stock 2.4 config, proxy modules enabled
│   └── apacheconf/
│       ├── sites/testlocal.conf
│       └── htmlfiles/index.html
└── app-server/
    ├── Dockerfile              # openjdk:8-jdk-alpine + jar  (BROKEN BASE)
    └── docker-message-server-1.0.0.jar
```

**Stands out immediately**
- Twelve files, one 29 MB binary, zero source code for the application **[FACT]**.
- Git history is a single commit made 2026-08-25 — three years of work (if any) collapsed into one snapshot **[FACT]**.
- Comments in the Dockerfiles are tutorial-didactic ("Remember, A Container is a Process...") — teaching material, not production docs **[FACT]**.

**Conspicuously absent**
- Any backend source, `pom.xml`/`build.gradle`, or build instructions **[FACT]**.
- Tests, CI, license file, CHANGELOG **[FACT]**.

**Experience signal:** the author was learning Docker and Apache proxying (verbose teaching comments, exploratory `start-command.txt`), while copying working patterns from a tutorial (correct Compose network, ProxyPass/ProxyPassReverse pairing) **[INFER]**.

---

## 3. Inferred Project Purpose & Scope

**What it appears to solve:** how to put Apache httpd in front of a containerized Spring Boot service, forwarding `/messages` to the backend over a Docker network **[INFER]**.

**Likely user:** the author, as a self-teaching exercise (Baeldung "Spring Cloud Config with Docker" line of tutorials) **[INFER — manifest package name is the evidence]**.

**Classification:** experiment / learning sandbox. Not a library or product.

**Strong evidence**
- Jar manifest `Start-Class: com.baeldung.spring.cloud.config.docker.DockerServer` **[FACT]**.
- Exactly two application classes in the jar: `DockerServer` (bootstrap) and `DockerMessageController` (`@GetMapping` → `/messages`) **[FACT]**.
- `application.properties` contains a single line: `server.port=8888` **[FACT]**.

**Weak/ambiguous signals**
- Compose network named `spring-cloud-network`, yet the jar contains **no Spring Cloud dependencies at all** — plain Spring Boot Web **[FACT + INFER: the name is aspirational, copied from the tutorial series]**.
- `start-command.txt` references `httpd-proxyenabled` (a locally built image?) and paths that don't exist in this repo — evidence of an earlier experimental phase **[FACT]**.

**Competing interpretation:** could be intended as a reusable proxy base image ("You can use the image to create N number of different virtual hosts" comment). Nothing in the repo commits to that **[SPEC]**.

---

## 4. Architecture & As Implemented

**Pattern:** side-by-side containers, reverse proxy in front, private bridge network, host port mapping (8080→80, 8889→8888) **[FACT]**.

**Control flow (verified at runtime)**
- `GET /` → served from DocumentRoot `/usr/local/apache2/testlocal` → `index.html` → **200** **[FACT]**.
- `GET /messages` → `ProxyPass` → `http://app-server:8888/messages` → **500 Proxy Error (DNS lookup failure for app-server)** when backend absent — wiring and failure mode both correct **[FACT]**.
- `GET /nonexistent` → **404** from Apache **[FACT]**.

**Design vs accretion:** accreted. The `IncludeOptional conf/sites/*.conf` hook is real design intent; the rest is a stock `httpd.conf` (500+ lines, ~90% upstream boilerplate) with modules uncommented as needed **[FACT]**.

**Boundaries respected:** yes — proxy knows the backend only by service name; backend knows nothing of the proxy. Clean **[FACT]**.

**Implied but not enforced:**
- "Cluster" in the repo name implies multiple backends / load balancing; `mod_proxy_balancer` and all three lbmethod modules are loaded, but no balancer is configured — capacity implied, unused **[FACT]**.
- Dual-publishing port 8889 "direct to backend" undermines the proxy-only boundary; fine for debugging, would be a bypass in production **[INFER]**.

---

## 5. Code Quality & Engineering Discipline

There is almost no first-party code — Dockerfiles, Apache configs, one HTML file, and a prebuilt binary.

**Dockerfiles**
- reverse-proxy: readable, commented, installs `ping`/`curl` for debugging (reasonable in a lab image; attack-surface and size cost) **[FACT]**.
- app-server: 3 lines; would be fine if the base image existed **[FACT]**.
- Neither pins base image versions **[FACT]**.

**Apache config smells**
- `testlocal.conf` mixes Apache 2.2 and 2.4 access syntax (`Order allow,deny` + `Allow from all` alongside `Require all granted`) — works only because `mod_access_compat` is loaded; deprecated idiom **[FACT]**.
- ~30 proxy-family modules loaded, almost all unused (ftp, ajp, fcgi, scgi, uwsgi, fdpass, wstunnel, express, hcheck, balancer...) **[FACT]**.
- Startup log noise confirms unused-but-loaded modules: `AH01873 Init: Session Cache is not configured`, `AH02282 No slotmem from mod_heartmonitor` **[FACT]**.
- Commented-out SSL/`X-Forwarded-*` lines in the vhost are copy-paste scaffolding, not configuration **[FACT]**.

**Jar packaging defect:** test-scope libraries — `rest-assured` (plus its `groovy`, `hamcrest`, `json-path`, `tagsoup`, `xml-path` closure) — are packaged into the runtime fat jar. Roughly a dozen jars shipped to production that never execute there **[FACT]**. This means the Maven build used wrong scopes; source not present to verify why **[INFER]**.

**`start-command.txt`:** stale, partially wrong (references `/apacheconf/sites` at repo root vs actual `reverse-proxy/apacheconf/sites`; image `httpd-proxyenabled` not buildable from this repo; contains a typo `– name` using an en-dash that would fail if copy-pasted) **[FACT]**. Kept deliberately as legacy reference per CLAUDE.md — defensible, but it is dead weight.

**Expensive-future-change hotspots:** the 500-line stock `httpd.conf` (every upstream change must be re-merged by hand), and the binary jar (any backend change requires source recovery first).

---

## 6. Testing Posture

**None.** No test files, no test framework config, no smoke script, no healthchecks in Compose **[FACT]**.

The only "verification" possible today is manual curl. This review's runtime checks (200/500/404 above) are now the most complete verification the project has ever had — and they live in a document, not an executable **[FACT]**.

**Untested critical behavior:** proxy-to-backend forwarding has never been demonstrated in-repo (it was verified here only in its failure mode, since the backend cannot build) **[FACT]**.

---

## 7. Documentation & Knowledge Transfer

- **README.md, CLAUDE.md** (AGENTS.md symlink), **.gitignore**: all created 2026-08-25, i.e., *three years younger than the code*, written alongside this review. They accurately describe the repo (endpoints and behavior runtime-verified), but a reader should know the docs are post-hoc reconstruction, not contemporaneous design records **[FACT]**.
- README quality: honest about the legacy `start-command.txt` and the static-content arrangement; commands are copy-pasteable **[FACT]**.
- Onboarding time for a cold clone: ~15 minutes to read everything, then immediate failure at `docker compose up --build` because of the dead base image — the docs can't fix what the Dockerfile breaks **[FACT]**.
- **Bus factor: 1**, and even that person holds no backend source — the true bus factor for the jar is zero **[INFER]**.

---

## 8. Tooling, Dependencies & Build Signals

| Artifact | State | Evidence |
|---|---|---|
| Backend base image | `openjdk:8-jdk-alpine` — **removed upstream, build fails** | reproduce: compose build error **[FACT]** |
| Proxy base image | `httpd:latest` — floats; currently 2.4.68 / OpenSSL 3.5.6 | `httpd -v` in container **[FACT]** |
| Compose file | `version: '2'` key obsolete (Compose warns on every run) | warning output **[FACT]** |
| Jar | Spring Boot 2.4.3 / Spring 5.3.4 (Feb 2021 stack), logback 1.2.3, snakeyaml 1.27, jackson 2.11.4 | `BOOT-INF/lib` listing **[FACT]** |
| Java target | bytecode major 52 = Java 8 (built on JDK 11.0.17) — would run on a JRE 8 | class-file magic **[FACT]** |
| CI/CD | absent | no files **[FACT]** |

**Security/supply-chain notes**
- The bundled library versions carry multiple published CVEs known by 2026 (e.g., snakeyaml, logback, Spring Framework 5.3.x line). For a localhost demo the practical exposure is negligible; the point is that *nothing in the repo could address them even if it mattered* — no source, no build **[FACT + INFER]**.
- 29 MB binary committed to git — permanent repo bloat; git is a poor artifact store **[FACT]**.
- `EXPOSE 80` + `apt install` in proxy image: standard but unpinned `apt update` = non-reproducible layer **[FACT]**.

**Overengineering vs underengineering:** both, in different places — ~30 unused Apache modules loaded (over) versus zero pinning, zero CI, zero tests (under).

---

## 9. Product & User Experience (Inferred)

The "user" is a developer cloning this to see the proxy pattern. Their experience:
1. `docker compose up --build` → **fails** on the first build. Dead end unless they know to swap base images **[FACT]**.
2. If they fix that, everything else works and the mental model is simple: one URL prefix proxied, one static page, two published ports **[INFER]**.
3. Failure UX: backend down produces a raw Apache **500 Proxy Error** HTML page — acceptable for a lab, unbranded noise otherwise **[FACT]**.

Likely confusion points: why 8889 is published (debugging bypass), why the network is named "spring-cloud" when no Spring Cloud is present, and what `start-command.txt` is for. README now answers all three **[FACT]**.

---

## 10. Operational Readiness

**Deployability outside the author's machine: none** — doesn't even build on the author's machine **[FACT]**.

Missing, in ascending order of consequence:
- No healthchecks (Compose has none; Spring Boot actuator absent from the jar — no `/actuator/health` to even point one at) **[FACT]**.
- No restart policies on either service **[FACT]**.
- No resource limits **[FACT]**.
- Logging is stdout-only — good start, no rotation concern for a demo **[FACT]**.
- SSL terminated nowhere; all traffic plaintext HTTP (commented-out scaffolding only) **[FACT]**.

**What breaks in a real environment:** everything downstream of the build failure, then after that: DNS coupling to Docker service names (fine in Compose, wrong assumption elsewhere), and a backend with no graceful shutdown story (default Spring Boot behavior only) **[INFER]**.

---

## 11. Risk Analysis

| # | Risk | Likelihood | Impact | Horizon | Class |
|---|---|---|---|---|---|
| 1 | Stack unrunnable (dead base image) | **Certain — already true** | Total (project's only purpose is to run) | Now | Technical |
| 2 | Backend unpatchable (no source; 2021-era deps with known CVEs) | Certain if ever exposed | High if exposed, nil if local | Long | Security / maintenance |
| 3 | `httpd:latest` drift breaks proxy silently on next build | High | Medium | Short | Reproducibility |
| 4 | Knowledge loss: single commit, no history, tutorial provenance undocumented | Certain | Medium | Long | Ownership |
| 5 | Deprecated Apache 2.2 access syntax stops working when `mod_access_compat` is eventually removed | Medium | Low (one vhost) | Long | Technical debt |
| 6 | Repo carries 29 MB binary forever; clones bloated | Certain | Low | Long | Hygiene |

---

## 12. Missing Artifacts & Silent Assumptions

| Missing | Why it matters | Risk introduced |
|---|---|---|
| Backend source + `pom.xml` | Jar cannot be rebuilt, patched, or dependency-upgraded | #2 above — the single largest structural gap |
| Any test / smoke script | Nothing prevents the current total-breakage state from recurring silently | Breakage discovered by humans, late |
| CI | No build validation; today's fatal error would have been caught by one `docker compose build` job | Regression risk |
| Image pinning / digests | Builds mean different things next month | Non-reproducibility |
| Healthchecks + restart policy | Demo of a *proxy cluster* with no liveness story | Ironic gap at minimum |
| LICENSE | Legal ambiguity if repo ever goes public | Low, but free to fix |
| Compose `down`/teardown notes | Minor; README covers run only | Negligible |
| Statement of tutorial provenance | README/CLAUDE.md don't mention the Baeldung origin **[FACT]** | Attribution/expectation clarity |

**Silent assumptions:** Docker Hub availability of `httpd:latest`; that "latest" httpd keeps `mod_access_compat`; that the 2023 jar's bytecode (Java 8) will meet a compatible JRE once a base is chosen.

---

## 13. Improvement Recommendations

Prioritized, repo-constrained (no rewrite of the app, which has no source):

**P1 — Restore runnability. Swap the app-server base image.**
- Evidence: build fails on `openjdk:8-jdk-alpine` **[FACT]**; jar targets Java 8 bytecode **[FACT]**.
- Change: `FROM eclipse-temurin:8-jre-alpine` (Temurin is the maintained successor line; JDK not needed at runtime — a JRE suffices for a packaged jar). Availability of this tag verified via `docker manifest inspect` during this review.
- Benefit: entire project runs again; ~5 minutes effort.
- Risk of ignoring: project stays dead.

**P2 — Pin what you can.**
- Evidence: `httpd:latest` floating (2.4.68 today, different next year) **[FACT]**; Compose warns about obsolete `version` key **[FACT]**.
- Change: `FROM httpd:2.4.68` (or a digest), delete the `version:` line from docker-compose.yml.
- Benefit: reproducible builds; ~10 minutes.
- Risk of ignoring: silent drift; the same class of failure that already killed the backend.

**P3 — Make verification executable.**
- Evidence: this review is the only end-to-end check ever performed, and it's prose **[FACT]**.
- Change: `scripts/smoke.sh` — compose up, curl `/` (expect 200), curl `/messages` (expect 200), compose down; wire into a one-job GitHub Actions workflow that runs `docker compose build` + the script.
- Benefit: breakage like P1 can never land silently again; ~1 hour.

**P4 — Recover or freeze the backend source.**
- Evidence: two classes total (`DockerServer`, `DockerMessageController`) — trivially small **[FACT]**; provenance known (Baeldung tutorial line).
- Change: either recreate the ~50-line Maven project in-repo (making the jar buildable and deps fixable), or add `NOTICE` documenting the jar as a frozen 2023 artifact of tutorial origin.
- Benefit: converts an opaque 29 MB liability into either maintainable code or an explicitly scoped artifact; 1–2 hours vs 15 minutes.

**P5 — Config hygiene.**
- Evidence: 2.2/2.4 syntax mix, ~30 unused modules, startup warnings **[FACT]**.
- Change: drop `Order/Allow` lines (keep `Require all granted`), comment out unused `LoadModule` lines, drop the dual `apt install` or pin it.
- Benefit: smaller image, cleaner logs, future-proof syntax; ~30 minutes.

**Recommendation against:** don't add Kubernetes files, TLS, or a real load balancer config. The repo's value is as a minimal teaching example; gold-plating a dead tutorial exceeds its intent **[INFER]**.

---

## 14. Perspective Shifts

**New developer cloning cold:** "README is clear, compose fails immediately. One Dockerfile edit (base image) and it works. The jar is a black box but it serves `/messages`. Why is the network called spring-cloud? Moving on." Time to first success if they diagnose the image issue themselves: ~20 minutes **[INFER]**.

**Maintainer inheriting it:** inherits a binary they can't rebuild, one commit of history, and docs younger than the code. Their first act would be P1 and P4, in that order. Reasonable afternoon of work to a runnable, honest state **[INFER]**.

**Product owner funding it:** nothing here to fund — no product, no users, no differentiation from the tutorial it came from. Value is entirely the author's learning, already banked **[INFER]**.

**Security reviewer:** plaintext HTTP everywhere (fine for local lab); unpinned bases and unbuildable backend make vulnerability management impossible in principle; test libraries shipped in runtime image; no secrets in repo (correctly none). Verdict: harmless as long as it stays on localhost; do not expose 8080/8889 beyond the machine **[FACT + INFER]**.

---

## 15. Final Verdict

**Trust earned:** as a *runnable system*, none today — it does not build. As an *archaeological record of a 2023 learning exercise*, complete and legible.

**What it is:** a dormant tutorial follow-along (Apache proxying in front of a Spring Boot toy service), minimally revived in 2026 with docs, then killed in effect by an upstream base-image removal it never insulated itself from.

**What it could become without heroic effort:** a clean, pinned, self-verifying two-container demo (P1–P3 = under two hours of work). That version would be genuinely useful as a reference example of the reverse-proxy pattern.

**Signal:** this repo signals **interruption, then partial transition** — a 2023 experiment shelved mid-learning (the stale `start-command.txt`, aspirational "cluster"/"spring-cloud" naming), picked up in 2026 just enough to document and preserve. Whether it gets revived or archived is the real open decision; either is defensible, but the current half-state — documented, committed, and unrunnable — is the one state worth nothing.

---

*Generated 2026-08-25. All runtime findings reproduced from `docker compose build/up` and `curl` against the running proxy container on that date.*
