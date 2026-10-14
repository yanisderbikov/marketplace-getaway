#!/usr/bin/env bash
# Разовая подготовка своего сервера (Ubuntu/Debian) под marketplace. Запуск: ssh root@сервер 'bash -s' < deploy/bootstrap.sh
# Ставит Docker, создаёт сеть marketplace, PostgreSQL в томе и заготовки env-файлов в /etc/marketplace.
# Git и исходники на сервере не нужны: сами сервисы приезжают образами из GHCR через GitHub Actions.
set -euo pipefail

PLATFORM_DOMAIN="${PLATFORM_DOMAIN:-yanderbikov.ru}"
ACME_EMAIL="${ACME_EMAIL:-admin@${PLATFORM_DOMAIN}}"
SERVER_IP="${SERVER_IP:-$(curl -4 -s https://ifconfig.me || true)}"

if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

docker network inspect marketplace >/dev/null 2>&1 || docker network create marketplace

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
ALLOWED_ORIGINS=https://${PLATFORM_DOMAIN},https://www.${PLATFORM_DOMAIN}
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
EMAIL_NOTISEND_EMAIL_ADDRESS=noreply@${PLATFORM_DOMAIN}
EMAIL_NOTISEND_FROM_NAME=marketplace
SDEK_TARIFF_CODE=136
PAYMENT_TINKOFF_API_URL=https://securepay.tinkoff.ru/v2
PAYMENT_TINKOFF_NOTIFICATION_URL=https://${PLATFORM_DOMAIN}/api/public/payment/tinkoff-webhook
PAYMENT_SECRETS_KEY=$(openssl rand -base64 32 | tr -d '\n')
PAYMENT_ALLOWED_RETURN_HOSTS=${PLATFORM_DOMAIN},www.${PLATFORM_DOMAIN}
PAYMENT_PENDING_CHECK_INTERVAL_MS=60000
DOMAIN_PROVISIONER=static
DOMAIN_CNAME_TARGET=shops.${PLATFORM_DOMAIN}
DOMAIN_A_RECORD_IP=${SERVER_IP}
EOT
  chmod 600 /etc/marketplace/back.env
fi

# ── Гейтвей ──
if [ ! -f /etc/marketplace/gateway.env ]; then
  cat > /etc/marketplace/gateway.env <<EOT
GATEWAY_MODE=tls
PLATFORM_DOMAIN=${PLATFORM_DOMAIN}, www.${PLATFORM_DOMAIN}
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

echo "ok: docker $(docker --version | cut -d' ' -f3), сеть marketplace, marketplace-db, /etc/marketplace/{db,back,gateway}.env"
echo "дальше: заполнить пустые переменные в /etc/marketplace/back.env и запустить деплой из GitHub Actions"
