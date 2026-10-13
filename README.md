# marketplace-gateway

Единая точка входа **marketplace**: принимает весь внешний трафик — домен платформы и свои домены
магазинов — и раскладывает его по сервисам. Сам ничего не хранит и не знает о магазинах: чья витрина
на домене, решает бэкенд.

Стек: [Caddy 2.11](https://caddyserver.com) (официальный образ `caddy:2.11-alpine`) + entrypoint-скрипт.

## Как устроено

```
                         ┌──────────────────────── marketplace-gateway ───────────────────────┐
 market.ru          ───► │  /api/*  ──► marketplace-back  (Spring, :8090)                     │
 shop.merchant.ru   ───► │  /healthz ─► 200 ok                                                │
 магазин.рф         ───► │  всё остальное ──► marketplace-front (nginx со SPA, :80)           │
                         └────────────────────────────────────────────────────────────────────┘
```

- **Каждый сервис — отдельный контейнер и отдельный репозиторий**: `marketplace-front`, `marketplace-back`,
  `marketplace-gateway`, плюс PostgreSQL. Общего docker-compose нет: сервисы знают друг о друге только
  через переменные `BACKEND_UPSTREAM` / `FRONTEND_UPSTREAM` (гейтвей) и `POSTGRES_URL` (бэкенд).
- **API всегда на том же origin, что и страница.** Фронт собирается с пустым `VITE_API_URL` и ходит на
  `/api/*` своего же хоста. Поэтому витрине на домене мерчанта не нужен CORS бэкенда.
- **Свой домен магазина.** Мерчант указывает домен в «Настройках» кабинета (`PUT /api/merchant/shop/domain`).
  Фронт, открытый не на хосте из `VITE_PLATFORM_HOSTS`, спрашивает `GET /api/public/domains/resolve?domain=<host>`
  и открывает витрину этого магазина с корня (`/`, `/product/…`, `/cart`, …). Адрес `/shop/{slug}` на
  платформе продолжает работать. `www.` домена ведёт в тот же магазин.
- **IP клиента.** Бэкенд считает лимиты по последнему элементу `X-Forwarded-For`. Гейтвей перезаписывает
  этот заголовок одним адресом клиента (`{client_ip}`); в режиме `proxied` Caddy сам разбирает цепочку
  прокси Railway справа налево и пропускает доверенные внутренние адреса (`TRUSTED_PROXIES`).

## Режимы

| `GATEWAY_MODE` | Где | TLS | Домены магазинов |
|---|---|---|---|
| `proxied` | Railway (или за любым балансировщиком) | снаружи, Caddy слушает HTTP на `$PORT` | каждый домен добавляется к сервису гейтвея в Railway (он и выпускает сертификат) |
| `tls` | свой сервер | Caddy сам на 80/443, Let's Encrypt | **on-demand TLS**: сертификат выпускается при первом заходе, если бэкенд ответил 200 на `resolve` — ничего добавлять руками не нужно |

## Переменные окружения

| Переменная | Режим | Что это |
|---|---|---|
| `GATEWAY_MODE` | оба | `proxied` или `tls` |
| `BACKEND_UPSTREAM` | оба | `host:port` бэкенда, например `back.railway.internal:8090` или `marketplace-back:8090` |
| `FRONTEND_UPSTREAM` | оба | `host:port` фронта, например `front.railway.internal:80` или `marketplace-front:80` |
| `PORT` | proxied | порт HTTP (Railway задаёт сам), по умолчанию 8080 |
| `TRUSTED_PROXIES` | proxied | чьему `X-Forwarded-For` верить, по умолчанию `private_ranges` (внутренняя сеть Railway) |
| `PLATFORM_DOMAIN` | tls | домен(ы) платформы, через запятую: `market.ru, www.market.ru` |
| `ACME_EMAIL` | tls | почта для Let's Encrypt |

Без обязательной переменной контейнер не стартует — запасных адресов нет нарочно.

## Railway (стенд)

Проект: 4 сервиса в одном окружении, наружу открыт только гейтвей.

| Сервис | Источник | Приватный адрес | Публичный домен |
|---|---|---|---|
| `Postgres` | шаблон Railway | `postgres.railway.internal:5432` | — |
| `back` | GitHub `marketplace-back` | `back.railway.internal:8090` | — |
| `front` | GitHub `marketplace-front` | `front.railway.internal:80` | — |
| `gateway` | GitHub `marketplace-gateway` | — | `*.up.railway.app` + домен платформы + домены магазинов |

Сборка и healthcheck каждого сервиса — в его `railway.toml`.

Переменные `gateway`: `GATEWAY_MODE=proxied`, `BACKEND_UPSTREAM=back.railway.internal:8090`,
`FRONTEND_UPSTREAM=front.railway.internal:80`.

**Подключить домен магазина на Railway:** мерчант сохраняет домен в кабинете, затем домен добавляется
к сервису `gateway` (Settings → Networking → Custom Domain, или `railway domain <домен> --service gateway`).
Railway покажет CNAME (и TXT для проверки) — их мерчант прописывает у своего регистратора.
На своём сервере этот ручной шаг не нужен (on-demand TLS).

## Свой сервер (прод)

Все контейнеры — в одной docker-сети, наружу открыт только гейтвей (80/443). Образы собираются из
своих репозиториев (`docker build`) или берутся из реестра.

```bash
docker network create marketplace

# PostgreSQL (данные — в томе)
docker run -d --name marketplace-db --network marketplace --restart unless-stopped \
  -e POSTGRES_DB=marketplace -e POSTGRES_USER=marketplace -e POSTGRES_PASSWORD=… \
  -v marketplace-db:/var/lib/postgresql/data postgres:16-alpine

# Бэкенд: переменные — см. marketplace-back/.env.example
docker run -d --name marketplace-back --network marketplace --restart unless-stopped \
  --env-file /etc/marketplace/back.env marketplace-back

# Фронт: VITE_* вшиты при сборке (VITE_API_URL пустой, VITE_PLATFORM_HOSTS=market.ru,www.market.ru)
docker run -d --name marketplace-front --network marketplace --restart unless-stopped marketplace-front

# Гейтвей: сертификаты Let's Encrypt — в томе /data, без него они перевыпускались бы при каждом рестарте
docker run -d --name marketplace-gateway --network marketplace --restart unless-stopped \
  -p 80:80 -p 443:443 -p 443:443/udp \
  -e GATEWAY_MODE=tls \
  -e PLATFORM_DOMAIN="market.ru, www.market.ru" \
  -e ACME_EMAIL=admin@market.ru \
  -e BACKEND_UPSTREAM=marketplace-back:8090 \
  -e FRONTEND_UPSTREAM=marketplace-front:80 \
  -v marketplace-caddy:/data marketplace-gateway
```

Ключевые переменные бэкенда для сервера: `POSTGRES_URL=jdbc:postgresql://marketplace-db:5432/marketplace`,
`FRONT_URL=https://market.ru`, `ALLOWED_ORIGINS=https://market.ru`,
`PAYMENT_TINKOFF_NOTIFICATION_URL=https://market.ru/api/public/payment/tinkoff-webhook`,
`PAYMENT_ALLOWED_RETURN_HOSTS=market.ru` (домены магазинов бэкенд разрешает сам).

**DNS для мерчантов на своём сервере:** заведите, например, `shops.market.ru` (A-запись на IP сервера) и
соберите фронт с `VITE_CUSTOM_DOMAIN_TARGET=shops.market.ru` — кабинет подскажет мерчанту сделать CNAME
своего домена на него (корневой домен — A-запись на тот же IP).

**Переезд с Railway:** `pg_dump` базы Railway → `pg_restore` в `marketplace-db`; секреты бэкенда
(`PAYMENT_SECRETS_KEY` обязательно тот же — им зашифрованы ключи платёжек и СДЭК, `JWT_SECRET` — чтобы не
разлогинить мерчантов) переносятся как есть; DNS домена платформы и доменов магазинов переводится на сервер.

## Локальная проверка

```bash
docker build -t marketplace-gateway .
docker run --rm -p 8080:8080 -e GATEWAY_MODE=proxied \
  -e BACKEND_UPSTREAM=host.docker.internal:8090 -e FRONTEND_UPSTREAM=host.docker.internal:3000 \
  marketplace-gateway
curl -H 'Host: shop.example.ru' localhost:8080/api/public/domains/resolve?domain=shop.example.ru
```
