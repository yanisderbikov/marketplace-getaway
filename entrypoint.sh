#!/bin/sh
# Выбирает конфиг по GATEWAY_MODE и проверяет обязательные переменные: значений по умолчанию
# для адресов нет нарочно — гейтвей без них не должен тихо проксировать «куда-то».
set -eu

require() {
	for name in "$@"; do
		eval "value=\${$name:-}"
		if [ -z "$value" ]; then
			echo "gateway: переменная $name не задана" >&2
			exit 1
		fi
	done
}

require GATEWAY_MODE BACKEND_UPSTREAM FRONTEND_UPSTREAM

case "$GATEWAY_MODE" in
	proxied) ;;
	tls) require PLATFORM_DOMAIN ACME_EMAIL ;;
	*)
		echo "gateway: GATEWAY_MODE должен быть proxied или tls, а не '$GATEWAY_MODE'" >&2
		exit 1
		;;
esac

exec caddy run --config "/etc/caddy/Caddyfile.$GATEWAY_MODE" --adapter caddyfile
