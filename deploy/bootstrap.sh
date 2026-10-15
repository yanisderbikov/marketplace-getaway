#!/usr/bin/env bash
# Разовая подготовка своего сервера (Ubuntu/Debian) под marketplace:
#   scp deploy/watcher.sh root@<ip>:/usr/local/bin/marketplace-deploy
#   PLATFORM_DOMAIN=marketplace.market.ru ssh root@<ip> 'bash -s' < deploy/bootstrap.sh
# Ставит Docker, создаёт сеть marketplace, PostgreSQL в томе, заготовки env-файлов в /etc/marketplace
# и systemd-таймер marketplace-deploy (раз в минуту тянет новые образы из GHCR, см. watcher.sh).
# Git и исходники на сервере не нужны: сервисы приезжают образами, которые собирает GitHub Actions из main.
set -euo pipefail

PLATFORM_DOMAIN="${PLATFORM_DOMAIN:-marketplace.yanderbikov.ru}"
ACME_EMAIL="${ACME_EMAIL:-admin@${PLATFORM_DOMAIN#*.}}"
# Корневой домен (market.ru) обслуживаем и с www.; поддомен (marketplace.market.ru) — только сам.
case "$PLATFORM_DOMAIN" in
  *.*.*) PLATFORM_HOSTS="$PLATFORM_DOMAIN"; CADDY_HOSTS="$PLATFORM_DOMAIN" ;;
  *)     PLATFORM_HOSTS="${PLATFORM_DOMAIN},www.${PLATFORM_DOMAIN}"; CADDY_HOSTS="${PLATFORM_DOMAIN}, www.${PLATFORM_DOMAIN}" ;;
esac
ROOT_DOMAIN="${PLATFORM_DOMAIN#*.}"; case "$PLATFORM_DOMAIN" in *.*.*) ;; *) ROOT_DOMAIN="$PLATFORM_DOMAIN" ;; esac
SERVER_IP="${SERVER_IP:-$(curl -4 -s https://ifconfig.me || true)}"

# ── Swap: JVM бэкенда + PostgreSQL на 1 ГБ RAM без swap упираются в OOM ──
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -w vm.swappiness=10 >/dev/null; echo 'vm.swappiness=10' > /etc/sysctl.d/90-swap.conf
fi

if ! command -v docker >/dev/null; then
  if ! curl -fsSL https://get.docker.com | sh; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q && apt-get install -y -q docker.io
  fi
fi
systemctl enable --now docker

# ── Docker-сеть с MTU внешнего интерфейса: у многих VPS он 1450, а docker по умолчанию ставит 1500,
# из-за чего TLS-рукопожатия с частью хостов (NotiSend, ZeroSSL) из контейнеров зависают.
HOST_MTU=$(ip -o link show "$(ip route show default | awk '{print $5; exit}')" | awk '{print $5}')
HOST_MTU=${HOST_MTU:-1500}
printf '{"mtu": %s}\n' "$HOST_MTU" > /etc/docker/daemon.json
NET_MTU=$(docker network inspect marketplace -f '{{index .Options "com.docker.network.driver.mtu"}}' 2>/dev/null || echo missing)
if [ "$NET_MTU" != "$HOST_MTU" ]; then
  attached=$(docker network inspect marketplace -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || true)
  for c in $attached; do docker network disconnect marketplace "$c"; done
  [ "$NET_MTU" != missing ] && docker network rm marketplace >/dev/null
  docker network create --opt com.docker.network.driver.mtu="$HOST_MTU" marketplace >/dev/null
  for c in $attached; do docker network connect marketplace "$c"; done
  echo "сеть marketplace пересоздана с MTU $HOST_MTU${attached:+, переподключены: $attached}"
fi

install -d -m 700 /etc/marketplace

# ── PostgreSQL ──
if [ ! -f /etc/marketplace/db.env ]; then
  cat > /etc/marketplace/db.env <<EOT
POSTGRES_DB=marketplace
POSTGRES_USER=marketplace
POSTGRES_PASSWORD=$(openssl rand -hex 24)
EOT
  chmod 600 /etc/marketplace/db.env
fi
if ! docker inspect marketplace-db >/dev/null 2>&1; then
  docker run -d --name marketplace-db --network marketplace --restart unless-stopped \
    --env-file /etc/marketplace/db.env \
    --log-opt max-size=20m --log-opt max-file=5 \
    -v marketplace-db:/var/lib/postgresql/data postgres:16-alpine
fi

# ── Бэкенд: заготовка; секреты (S3, NotiSend, JWT, PAYMENT_SECRETS_KEY…) заполняются руками или копируются со стенда ──
if [ ! -f /etc/marketplace/back.env ]; then
  # shellcheck disable=SC1091
  . /etc/marketplace/db.env
  cat > /etc/marketplace/back.env <<EOT
ALLOWED_ORIGINS=https://${PLATFORM_DOMAIN}
FRONT_URL=https://${PLATFORM_DOMAIN}
POSTGRES_URL=jdbc:postgresql://marketplace-db:5432/${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
S3_BUCKET_NAME=
S3_REGION=ru-central1
S3_ENDPOINT=https://storage.yandexcloud.net
S3_ACCESS_KEY_ID=
S3_SECRET_ACCESS_KEY=
S3_CORS_AUTO=true
JWT_SECRET=$(openssl rand -base64 48 | tr -d '\n')
JWT_EXPIRATION_SECONDS=2592000
ADMIN_SUPER_EMAILS=
AUTH_LOGIN_CODE_SECRET=$(openssl rand -base64 32 | tr -d '\n')
EMAIL_NOTISEND_API_KEY=
EMAIL_NOTISEND_EMAIL_ADDRESS=noreply@${ROOT_DOMAIN}
EMAIL_NOTISEND_FROM_NAME=marketplace
SDEK_TARIFF_CODE=136
PAYMENT_TINKOFF_API_URL=https://securepay.tinkoff.ru/v2
PAYMENT_TINKOFF_NOTIFICATION_URL=https://${PLATFORM_DOMAIN}/api/public/payment/tinkoff-webhook
PAYMENT_SECRETS_KEY=$(openssl rand -base64 32 | tr -d '\n')
PAYMENT_ALLOWED_RETURN_HOSTS=${PLATFORM_HOSTS}
PAYMENT_PENDING_CHECK_INTERVAL_MS=60000
DOMAIN_PROVISIONER=static
DOMAIN_CNAME_TARGET=shops.${ROOT_DOMAIN}
DOMAIN_A_RECORD_IP=${SERVER_IP}
EOT
  chmod 600 /etc/marketplace/back.env
fi

# ── Гейтвей ──
if [ ! -f /etc/marketplace/gateway.env ]; then
  cat > /etc/marketplace/gateway.env <<EOT
GATEWAY_MODE=tls
PLATFORM_DOMAIN=${CADDY_HOSTS}
ACME_EMAIL=${ACME_EMAIL}
BACKEND_UPSTREAM=marketplace-back:8090
FRONTEND_UPSTREAM=marketplace-front:80
EOT
  chmod 600 /etc/marketplace/gateway.env
fi

# ── Файрвол: наружу только SSH и гейтвей ──
if command -v ufw >/dev/null; then
  ufw allow OpenSSH >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; ufw allow 443/udp >/dev/null
  ufw --force enable >/dev/null
fi

# ── Вотчер деплоя: systemd-таймер раз в минуту ──
if [ -f /usr/local/bin/marketplace-deploy ]; then
  chmod 755 /usr/local/bin/marketplace-deploy
  cat > /etc/systemd/system/marketplace-deploy.service <<EOT
[Unit]
Description=marketplace: pull new images from GHCR and roll containers
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/marketplace-deploy
EOT
  cat > /etc/systemd/system/marketplace-deploy.timer <<EOT
[Unit]
Description=marketplace deploy watcher (every minute)

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOT
  systemctl daemon-reload
  systemctl enable --now marketplace-deploy.timer
else
  echo "ВНИМАНИЕ: /usr/local/bin/marketplace-deploy не найден — сначала scp deploy/watcher.sh" >&2
fi

echo "ok: docker $(docker --version | cut -d' ' -f3), сеть marketplace, marketplace-db, /etc/marketplace/{db,back,gateway}.env, таймер marketplace-deploy"
echo "дальше: заполнить пустые переменные в /etc/marketplace/back.env; логи деплоя — journalctl -u marketplace-deploy"
