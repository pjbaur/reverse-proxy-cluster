# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

Docker Compose demo: an Apache HTTP Server (`httpd`) reverse proxy in front of a Java message server (`app-server`). The proxy publishes host port 8080 and forwards `/messages` to `app-server:8888` over the `spring-cloud-network` bridge network. See README.md for full architecture and configuration details.

There is no build system in this repository. The backend ships as a prebuilt jar (`app-server/docker-message-server-1.0.0.jar`); the proxy image is built from `reverse-proxy/Dockerfile`. There are no tests.

## Commands

```sh
# Start both containers (build images if needed)
docker compose up --build

# Stop
docker compose down

# Rebuild from scratch after config changes
docker compose up --build --force-recreate
```

Smoke tests:

```sh
curl http://localhost:8080/messages   # through the reverse proxy
curl http://localhost:8889/messages   # backend directly
```

## Structure

- `docker-compose.yml` — service definitions, port mappings, network
- `reverse-proxy/httpd.conf` — base Apache config; proxy modules enabled; loads `conf/sites/*.conf` via `IncludeOptional`
- `reverse-proxy/apacheconf/sites/` — virtual host configs (currently `testlocal.conf`); copied into the image at build time, so changes require a rebuild
- `reverse-proxy/apacheconf/htmlfiles/` — static content for the virtual host
- `app-server/` — Dockerfile plus the prebuilt jar

## Notes

- Static content for the virtual host (`apacheconf/htmlfiles/`) is baked into the image at `/usr/local/apache2/testlocal`; changes require a rebuild.
- `start-command.txt` is a legacy pre-Compose manual `docker run` command. Keep as reference; do not update it to match the Compose setup.
- Apache config changes (vhosts, `httpd.conf`) are baked into the image, not bind-mounted — always rebuild rather than expecting live reload.
