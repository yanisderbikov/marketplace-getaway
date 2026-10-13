FROM caddy:2.11-alpine

COPY snippets.caddy Caddyfile.proxied Caddyfile.tls /etc/caddy/
COPY entrypoint.sh /usr/local/bin/gateway-entrypoint

# 8080 — режим proxied ($PORT), 80/443 — режим tls. Сертификаты и ключи ACME — в /data (том на своём сервере).
EXPOSE 8080 80 443

ENTRYPOINT ["/usr/local/bin/gateway-entrypoint"]
