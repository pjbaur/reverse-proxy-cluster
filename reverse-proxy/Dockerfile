# Patch-pinned: the proxy is the demo's subject — reproducibility matters most here.
FROM httpd:2.4.68-alpine

# Trimmed base config (2.4-only syntax, 14 modules), lands in the stock path.
COPY httpd.conf /usr/local/apache2/conf/httpd.conf

# Per-topic config: status policy, forward headers, one file per backend route,
# TLS vhost. COPY creates conf/sites/ automatically.
COPY apacheconf/sites/ /usr/local/apache2/conf/sites/

# Landing page served from DocumentRoot.
COPY apacheconf/htdocs/ /usr/local/apache2/htdocs/

# Dev TLS certificate from scripts/gen-dev-certs.sh (gitignored).
# If this COPY fails with "not found": run scripts/gen-dev-certs.sh, rebuild.
COPY certs/server.crt certs/server.key /usr/local/apache2/conf/certs/

EXPOSE 80 443

# httpd-foreground is the stock entrypoint of the httpd image (httpd -D FOREGROUND).
CMD ["httpd-foreground"]
