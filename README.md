# reverse-proxy-cluster

A small Docker Compose demo that runs an Apache HTTP Server (`httpd`) as a reverse proxy in front of a Java backend service. The proxy listens on the outside port and forwards selected paths to the backend container over a private Docker bridge network.

## Architecture

```
client ──> :8080 ──> reverse-proxy (httpd)  ──/messages──> app-server:8888 (Java)
```

| Service        | Image                  | Host port | Container port | Purpose                                      |
| -------------- | ---------------------- | --------- | -------------- | -------------------------------------------- |
| reverse-proxy  | `httpd:latest` (custom)| 8080      | 80             | Apache reverse proxy, virtual host `test.local` |
| app-server     | `openjdk:8-jdk-alpine` | 8889      | 8888           | Runs `docker-message-server-1.0.0.jar`       |

Both services are attached to the `spring-cloud-network` bridge network, so the proxy reaches the backend via the Docker service name (`http://app-server:8888`).

## Project layout

```
docker-compose.yml                        # Service definitions and network
reverse-proxy/
  Dockerfile                              # httpd image with proxy modules enabled
  httpd.conf                              # Base Apache config; includes conf/sites/*.conf
  apacheconf/sites/testlocal.conf         # Virtual host: static content + ProxyPass rules
  apacheconf/htmlfiles/index.html         # Test page for the virtual host
app-server/
  Dockerfile                              # OpenJDK 8 image wrapping the message server jar
  docker-message-server-1.0.0.jar         # Backend application
start-command.txt                         # Legacy manual `docker run` notes (pre-Compose)
```

## Prerequisites

- Docker
- Docker Compose

## Run

From the repository root:

```sh
docker compose up --build
```

Or with older Compose versions:

```sh
docker-compose up --build
```

## Test

Proxy path (request hits Apache, which forwards to the backend):

```sh
curl http://localhost:8080/messages
```

Backend directly (bypasses the proxy, useful to compare responses):

```sh
curl http://localhost:8889/messages
```

The virtual host declares `ServerName test.local`. Since it is the only virtual host, Apache serves it for any host header, so `localhost` works without changes. To use the real name, add it to your hosts file:

```sh
echo "127.0.0.1 test.local www.test.local" | sudo tee -a /etc/hosts
curl http://test.local:8080/messages
```

## Configuration

- **Virtual hosts** live in `reverse-proxy/apacheconf/sites/`. The Dockerfile copies them into `/usr/local/apache2/conf/sites/`, and the base `httpd.conf` picks them up with `IncludeOptional conf/sites/*.conf`. Drop a new `*.conf` file in that directory and rebuild to add another virtual host.
- **Proxy rules** are `ProxyPass` / `ProxyPassReverse` directives in `testlocal.conf`, currently mapping `/messages` to `http://app-server:8888/messages`. The commented-out directives in that file show how to enable SSL termination (`SSLProxyEngine`) and set `X-Forwarded-Proto` / `X-Forwarded-Port` headers.
- **Proxy modules** (`mod_proxy`, `mod_proxy_http`, `mod_proxy_balancer`, and the balancer LB methods, among others) are enabled in `httpd.conf`, so balancer/cluster configurations can be added without rebuilding the base config.

### Static content

The virtual host's `DocumentRoot` (`/usr/local/apache2/testlocal`) is populated at build time from `apacheconf/htmlfiles/`, so `http://localhost:8080/` serves `index.html`. Changes to the static files require a rebuild.

## Legacy notes

`start-command.txt` contains the earlier, manual `docker run` command used before this setup was containerized with Compose. It references volume mounts and an image name (`httpd-proxyenabled`) that predate the current build; keep it as reference only.
