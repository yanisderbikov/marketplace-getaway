#!/usr/bin/env bash
# marketplace-deploy — деплой прода «по pull»: раз в минуту (systemd-таймер) тянет :latest каждого сервиса
# из GHCR и, если образ изменился или контейнер пропал, перекатывает его и ждёт healthcheck.
# GitHub Actions только собирает образы; доступа к серверу у GitHub нет, git на сервере нет.
# Установка/обновление: scp deploy/watcher.sh root@<ip>:/usr/local/bin/marketplace-deploy (см. bootstrap.sh).
#
# Использование: marketplace-deploy [--force] [сервис…]   (сервисы: back front gateway)
set -euo pipefail

OWNER=yanisderbikov
NETWORK=marketplace
ENV_DIR=/etc/marketplace
CURL_IMAGE=curlimages/curl:8.10.1

log() { echo "$(date '+%F %T') $*"; }

exec 9>/run/lock/marketplace-deploy.lock
flock -n 9 || { log "уже выполняется, пропуск"; exit 0; }

FORCE=0
if [ "${1:-}" = "--force" ]; then FORCE=1; shift; fi

# Сервис → "репозиторий|доп. аргументы docker run|healthcheck внутри сети".
# Контейнер marketplace-<имя>, образ ghcr.io/<owner>/<репозиторий>:latest, env-файл /etc/marketplace/<имя>.env (если есть).
service_spec() {
  case "$1" in
    back)    echo "marketplace-back||http://marketplace-back:8090/api/actuator/health" ;;
    front)   echo "marketplace-front||http://marketplace-front:80/" ;;
    gateway) echo "marketplace-getaway|-p 80:80 -p 443:443 -p 443:443/udp -v marketplace-caddy:/data -v marketplace-caddy-config:/config|http://marketplace-gateway:80/healthz" ;;
    *) return 1 ;;
  esac
}

wait_healthy() { # name url
  local name=$1 url=$2 i
  for i in $(seq 1 60); do
    if docker run --rm --network "$NETWORK" "$CURL_IMAGE" -sf -o /dev/null --max-time 5 "$url" 2>/dev/null; then
      return 0
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" != "true" ]; then
      log "$name: контейнер упал"; docker logs --tail 80 "$name" 2>&1 | sed "s/^/  /"; return 1
    fi
    sleep 3
  done
  log "$name: healthcheck $url не ответил 2xx за 3 минуты"; docker logs --tail 80 "$name" 2>&1 | sed "s/^/  /"; return 1
}

deploy_one() { # svc
  local svc=$1 spec repo run_args health name image env_file new_id cur_id
  spec=$(service_spec "$svc") || { log "неизвестный сервис: $svc"; return 1; }
  IFS='|' read -r repo run_args health <<<"$spec"
  name="marketplace-$svc"; image="ghcr.io/$OWNER/$repo:latest"; env_file="$ENV_DIR/$svc.env"

  if ! docker pull -q "$image" >/dev/null 2>&1; then
    log "$name: не удалось скачать $image"; return 1
  fi
  new_id=$(docker image inspect -f '{{.Id}}' "$image")
  cur_id=$(docker inspect -f '{{.Image}}' "$name" 2>/dev/null || true)
  if [ "$FORCE" = 0 ] && [ "$new_id" = "$cur_id" ]; then
    return 0
  fi

  local env_arg=()
  [ -f "$env_file" ] && env_arg=(--env-file "$env_file")
  log "$name: ${cur_id:+обновление ${cur_id:7:12} → }${new_id:7:12}"
  docker rm -f "$name" >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  docker run -d --name "$name" --network "$NETWORK" --restart unless-stopped \
    --log-opt max-size=20m --log-opt max-file=5 \
    "${env_arg[@]}" $run_args "$image" >/dev/null
  if wait_healthy "$name" "$health"; then
    log "$name: ok, $(docker image inspect -f '{{index .RepoDigests 0}}' "$image" | sed 's/.*@sha256:/sha256:/' | cut -c1-19)"
  else
    return 1
  fi
}

docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK" >/dev/null

rc=0
for svc in ${*:-back front gateway}; do
  deploy_one "$svc" || rc=1
done
docker image prune -f >/dev/null 2>&1 || true
exit $rc
