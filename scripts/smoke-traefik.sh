#!/usr/bin/env bash
# Smoke test de Traefik + Consul Catalog.
#
# Levanta traefik/whoami en la red compartida, lo registra en Consul con tags
# de Traefik y un check HTTP, espera a que este passing y comprueba que
# Traefik lo rutee en /whoami. Al salir (OK o error) desregistra el servicio
# y borra el contenedor.
#
# Requiere consul y traefik levantados (docker compose up -d --wait).
# Uso:
#   scripts/smoke-traefik.sh
# Variables (si CONSUL_HTTP_TOKEN no esta en el entorno se lee de ENV_FILE,
# por defecto .env en la raiz del repo):
#   CONSUL_HTTP_TOKEN, SHARED_NETWORK, CONSUL_UI_PORT, TRAEFIK_PORT, TIMEOUT

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"

if [[ -z "${CONSUL_HTTP_TOKEN:-}" && -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

# Con default_policy deny hace falta un token con service:write sobre
# "whoami". Se usa el de management (CONSUL_HTTP_TOKEN, solo infra) porque es
# una prueba de la infraestructura: no tiene sentido una policy y un token
# permanentes para un servicio de prueba. Traefik lo lee con su propio token.
: "${CONSUL_HTTP_TOKEN:?Definir CONSUL_HTTP_TOKEN (entorno o ENV_FILE)}"
NETWORK="${SHARED_NETWORK:-mired}"
CONSUL_URL="http://127.0.0.1:${CONSUL_UI_PORT:-8500}"
TRAEFIK_URL="http://127.0.0.1:${TRAEFIK_PORT:-8080}"
TIMEOUT="${TIMEOUT:-60}"

IMAGE="traefik/whoami:v1.11.0"
NAME="smoke-whoami-$$"
SERVICE_ID="$NAME"
SERVICE_NAME="whoami"

log() { printf '[smoke] %s\n' "$*"; }

consul() {
  # consul METHOD PATH [curl args...]
  local method="$1" path="$2"
  shift 2
  curl -fsS -X "$method" -H "X-Consul-Token: $CONSUL_HTTP_TOKEN" "$CONSUL_URL$path" "$@"
}

cleanup() {
  local status=$?
  log "limpieza: desregistrando $SERVICE_ID y borrando el contenedor"
  consul PUT "/v1/agent/service/deregister/$SERVICE_ID" >/dev/null 2>&1 || true
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  if [[ $status -eq 0 ]]; then
    log "OK"
  else
    log "FALLO (exit $status)"
  fi
  exit "$status"
}
trap cleanup EXIT

# Espera hasta TIMEOUT segundos a que el comando devuelva 0.
wait_for() {
  local what="$1"
  shift
  local deadline=$((SECONDS + TIMEOUT))
  until "$@"; do
    if ((SECONDS >= deadline)); then
      log "timeout (${TIMEOUT}s) esperando: $what"
      return 1
    fi
    sleep 1
  done
}

log "levantando $IMAGE como $NAME en la red $NETWORK"
docker run -d --rm --name "$NAME" --network "$NETWORK" "$IMAGE" >/dev/null

log "registrando $SERVICE_ID en Consul"
consul PUT /v1/agent/service/register --data @- <<JSON
{
  "ID": "$SERVICE_ID",
  "Name": "$SERVICE_NAME",
  "Address": "$NAME",
  "Port": 80,
  "Tags": [
    "traefik.enable=true",
    "traefik.http.routers.whoami.rule=PathPrefix(\`/whoami\`)"
  ],
  "Check": {
    "HTTP": "http://$NAME:80/health",
    "Interval": "2s",
    "Timeout": "1s",
    "DeregisterCriticalServiceAfter": "1m"
  }
}
JSON

# El endpoint del agente responde 200 solo si todos los checks de la
# instancia estan passing (503 si alguno esta critical).
is_passing() {
  [[ "$(consul GET "/v1/agent/health/service/id/$SERVICE_ID?format=text" 2>/dev/null)" == "passing" ]]
}
log "esperando a que el check este passing"
wait_for "check passing" is_passing

routes_ok() {
  [[ "$(curl -s -o /dev/null -w '%{http_code}' "$TRAEFIK_URL/whoami")" == "200" ]]
}
log "esperando 200 en $TRAEFIK_URL/whoami"
wait_for "200 en /whoami" routes_ok

log "respuesta de whoami via Traefik:"
curl -fsS "$TRAEFIK_URL/whoami" | sed 's/^/    /'
