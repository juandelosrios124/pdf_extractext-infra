#!/usr/bin/env bash
# Smoke test del presupuesto de timeouts de Traefik (ver README, "Presupuesto
# de timeouts").
#
# Levanta traefik/whoami en la red compartida y lo registra en Consul con el
# serversTransport extract-transport@file, el mismo que usa extract. whoami
# demora la respuesta con ?wait=<duracion>. Comprueba:
#   1. wait=20s                      -> 200 (entra en el presupuesto).
#   2. wait=28s                      -> 504 de Traefik a los ~25 s
#                                       (responseHeaderTimeout).
#   3. wait=40s con subida lenta     -> 504 a los ~SLOW_UPLOAD+25 s: el
#      del body (SLOW_UPLOAD s)         writeTimeout del entrypoint cuenta la
#                                       subida y no tiene que cortar el 504.
# Al salir (OK o error) desregistra el servicio y borra el contenedor.
#
# Requiere consul y traefik levantados (docker compose up -d --wait).
# Tarda ~1,5 min. Uso:
#   scripts/smoke-timeouts.sh
# Variables (si CONSUL_HTTP_TOKEN no esta en el entorno se lee de ENV_FILE,
# por defecto .env en la raiz del repo):
#   CONSUL_HTTP_TOKEN, SHARED_NETWORK, CONSUL_UI_PORT, TRAEFIK_PORT,
#   TRAEFIK_DASHBOARD_PORT, TIMEOUT, CUT (s, responseHeaderTimeout esperado),
#   SLOW_UPLOAD (s)

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
# "smoke-timeouts". Se usa el de management (CONSUL_HTTP_TOKEN, solo infra) porque es
# una prueba de la infraestructura: no tiene sentido una policy y un token
# permanentes para un servicio de prueba. Traefik lo lee con su propio token.
: "${CONSUL_HTTP_TOKEN:?Definir CONSUL_HTTP_TOKEN (entorno o ENV_FILE)}"
NETWORK="${SHARED_NETWORK:-mired}"
CONSUL_URL="http://127.0.0.1:${CONSUL_UI_PORT:-8500}"
TRAEFIK_URL="http://127.0.0.1:${TRAEFIK_PORT:-8080}"
TRAEFIK_API="http://127.0.0.1:${TRAEFIK_DASHBOARD_PORT:-8081}"
TIMEOUT="${TIMEOUT:-60}"
# responseHeaderTimeout de extract-transport en traefik/dynamic.yml.
CUT="${CUT:-25}"
SLOW_UPLOAD="${SLOW_UPLOAD:-8}"
# Margen aceptado alrededor del corte esperado (segundos).
MARGIN_BEFORE=2
MARGIN_AFTER=2

IMAGE="traefik/whoami:v1.11.0"
NAME="smoke-timeouts-$$"
SERVICE_ID="$NAME"
SERVICE_NAME="smoke-timeouts"
ROUTE="/smoke-timeouts"
TRANSPORT="extract-transport@file"

log() { printf '[smoke-timeouts] %s\n' "$*"; }

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

# timed_request NOMBRE CODIGO MIN MAX [curl args...]
# Hace el pedido y falla si el codigo HTTP no es CODIGO o si la duracion total
# (segundos) queda fuera de [MIN, MAX].
timed_request() {
  local name="$1" want_code="$2" min="$3" max="$4"
  shift 4
  local out code took
  # Sin -f: el 504 es una respuesta esperada. curl sale con 52 si el servidor
  # cierra sin responder (lo que haria un writeTimeout demasiado corto).
  out=$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time 90 "$@") || {
    log "$name: curl fallo (exit $?) sin respuesta HTTP"
    return 1
  }
  read -r code took <<<"$out"
  log "$name: HTTP $code en ${took}s (esperado $want_code en [${min}s, ${max}s])"
  [[ $code == "$want_code" ]] || { log "$name: codigo inesperado"; return 1; }
  awk -v t="$took" -v lo="$min" -v hi="$max" 'BEGIN { exit !(t >= lo && t <= hi) }' \
    || { log "$name: duracion fuera de rango"; return 1; }
}

log "levantando $IMAGE como $NAME en la red $NETWORK"
docker run -d --rm --name "$NAME" --network "$NETWORK" "$IMAGE" >/dev/null

log "registrando $SERVICE_ID en Consul con serverstransport=$TRANSPORT"
consul PUT /v1/agent/service/register --data @- <<JSON
{
  "ID": "$SERVICE_ID",
  "Name": "$SERVICE_NAME",
  "Address": "$NAME",
  "Port": 80,
  "Tags": [
    "traefik.enable=true",
    "traefik.http.routers.$SERVICE_NAME.rule=PathPrefix(\`$ROUTE\`)",
    "traefik.http.routers.$SERVICE_NAME.entrypoints=web",
    "traefik.http.services.$SERVICE_NAME.loadbalancer.serverstransport=$TRANSPORT"
  ],
  "Check": {
    "HTTP": "http://$NAME:80/health",
    "Interval": "2s",
    "Timeout": "1s",
    "DeregisterCriticalServiceAfter": "1m"
  }
}
JSON

is_passing() {
  [[ "$(consul GET "/v1/agent/health/service/id/$SERVICE_ID?format=text" 2>/dev/null)" == "passing" ]]
}
log "esperando a que el check este passing"
wait_for "check passing" is_passing

routes_ok() {
  [[ "$(curl -s -o /dev/null -w '%{http_code}' "$TRAEFIK_URL$ROUTE")" == "200" ]]
}
log "esperando 200 en $TRAEFIK_URL$ROUTE"
wait_for "200 en $ROUTE" routes_ok

# Sin esto, un tag mal escrito haria pasar el caso 1 y fallar el 2 por
# "no corto", sin decir por que.
log "comprobando que el service de Traefik usa $TRANSPORT"
transport=$(curl -fsS "$TRAEFIK_API/api/http/services/$SERVICE_NAME@consulcatalog" \
  | jq -r '.loadBalancer.serversTransport // empty')
log "serversTransport: ${transport:-<ninguno>}"
[[ $transport == "$TRANSPORT" ]]

log "caso 1: wait=20s, dentro del presupuesto"
timed_request "wait=20s" 200 19 $((CUT - 1)) "$TRAEFIK_URL$ROUTE?wait=20s"

log "caso 2: wait=28s, Traefik tiene que cortar a los ~${CUT}s"
timed_request "wait=28s" 504 $((CUT - MARGIN_BEFORE)) $((CUT + MARGIN_AFTER)) \
  "$TRAEFIK_URL$ROUTE?wait=28s"

# Body de 40 KB a 5 KB/s: la subida dura ~SLOW_UPLOAD s. responseHeaderTimeout
# empieza a contar recien cuando Traefik termino de enviar el body a la replica,
# y writeTimeout cuenta desde los headers del request: el 504 sale a los
# ~SLOW_UPLOAD+CUT s, y con writeTimeout < SLOW_UPLOAD+CUT Traefik cerraria la
# conexion sin enviarlo.
body_kb=40
rate_kb=$((body_kb / SLOW_UPLOAD))
expected=$((SLOW_UPLOAD + CUT))
log "caso 3: wait=40s con subida de ${body_kb} KB a ${rate_kb} KB/s, 504 a los ~${expected}s"
timed_request "subida lenta" 504 $((expected - MARGIN_BEFORE)) $((expected + MARGIN_AFTER)) \
  -X POST --data-binary @<(head -c $((body_kb * 1024)) /dev/zero) \
  -H 'Content-Type: application/octet-stream' -H 'Expect:' --limit-rate "${rate_kb}k" \
  "$TRAEFIK_URL$ROUTE?wait=40s"
