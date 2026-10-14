#!/usr/bin/env bash
# Выполняется на сервере из GitHub Actions: тянет образ из GHCR и перезапускает контейнер.
# Вход: IMAGE (полный тег), NAME (имя контейнера), GHCR_USER, RUN_ARGS (доп. аргументы docker run),
# HEALTH_URL (адрес внутри docker-сети marketplace, по которому ждём 2xx; пусто — не ждать).
# Токен GHCR — в stdin (docker login --password-stdin). Git на сервере не нужен.
set -euo pipefail

: "${IMAGE:?}" "${NAME:?}" "${GHCR_USER:?}"
RUN_ARGS="${RUN_ARGS:-}"
HEALTH_URL="${HEALTH_URL:-}"
ENV_FILE="/etc/marketplace/${NAME#marketplace-}.env"
NETWORK=marketplace

docker login ghcr.io -u "$GHCR_USER" --password-stdin
docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK"
docker pull "$IMAGE"

env_file_arg=()
if [ -f "$ENV_FILE" ]; then env_file_arg=(--env-file "$ENV_FILE"); fi

# Старый контейнер гасим только после успешного pull — чтобы не остаться без сервиса из-за сетевой ошибки.
docker rm -f "$NAME" >/dev/null 2>&1 || true
# shellcheck disable=SC2086
docker run -d --name "$NAME" --network "$NETWORK" --restart unless-stopped \
  --log-opt max-size=20m --log-opt max-file=5 \
  "${env_file_arg[@]}" $RUN_ARGS "$IMAGE"

if [ -n "$HEALTH_URL" ]; then
  for i in $(seq 1 60); do
    if docker run --rm --network "$NETWORK" curlimages/curl:8.10.1 -sf -o /dev/null "$HEALTH_URL"; then
      echo "healthy: $HEALTH_URL"; break
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" != "true" ]; then
      echo "container $NAME died:"; docker logs --tail 100 "$NAME"; exit 1
    fi
    if [ "$i" = 60 ]; then echo "healthcheck timeout: $HEALTH_URL"; docker logs --tail 100 "$NAME"; exit 1; fi
    sleep 3
  done
fi

docker logout ghcr.io >/dev/null
docker image prune -f >/dev/null
docker ps --filter "name=$NAME" --format '{{.Names}} {{.Image}} {{.Status}}'
