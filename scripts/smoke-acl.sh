#!/usr/bin/env bash
# Smoke test de las ACL de Consul (default_policy deny, ver README, "ACL").
#
# Comprueba contra el Consul levantado:
#   1. Registrar sin token -> 403.
#   2. Token de extract: registra y desregistra "extract"; "documents" -> 403.
#   3. Token de documents: registra y desregistra "documents"; "extract" -> 403.
#   4. Token de Traefik: lee catalogo, health y nodos; registrar -> 403.
#   5. Sin token, el catalogo no expone servicios: Consul 2.0.4 responde
#      200 con {} (filtra el resultado, no devuelve 403).
#   6. El token del agente existe con la policy agent, el nodo "ds" tiene sus
#      direcciones en el catalogo y en el log de Consul no hay errores de ACL
#      del agente desde que termino consul-acl-init.
# Los servicios de prueba no tienen tags de Traefik: aunque extract y documents
# reales esten levantados, Traefik no les manda trafico. Al salir (OK o error)
# se desregistran con el token de management.
#
# Requiere consul, consul-acl-init y traefik levantados
# (docker compose up -d --wait). Uso:
#   scripts/smoke-acl.sh
# Variables (si falta alguna se leen de ENV_FILE, por defecto .env en la raiz
# del repo): CONSUL_HTTP_TOKEN, CONSUL_AGENT_TOKEN, CONSUL_TRAEFIK_TOKEN,
# CONSUL_EXTRACT_TOKEN, CONSUL_DOCUMENTS_TOKEN, CONSUL_UI_PORT.
# SINCE: desde cuando se revisa el log de Consul (formato de
# "docker logs --since"); por defecto, el fin de consul-acl-init.
# Nunca imprime los tokens: viajan en el header por un descriptor (-H @fd),
# no en la linea de comandos.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"
TOKEN_VARS=(CONSUL_HTTP_TOKEN CONSUL_AGENT_TOKEN CONSUL_TRAEFIK_TOKEN CONSUL_EXTRACT_TOKEN CONSUL_DOCUMENTS_TOKEN)

missing=0
for var in "${TOKEN_VARS[@]}"; do
  [[ -n "${!var:-}" ]] || missing=1
done
if ((missing)) && [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi
for var in "${TOKEN_VARS[@]}"; do
  [[ -n "${!var:-}" ]] || { echo "Definir $var (entorno o ENV_FILE)" >&2; exit 1; }
done

CONSUL_URL="http://127.0.0.1:${CONSUL_UI_PORT:-8500}"
COMPOSE=(docker compose --project-directory "$REPO_DIR")
[[ -f "$ENV_FILE" ]] && COMPOSE+=(--env-file "$ENV_FILE")
PREFIX="smoke-acl-$$"
FAILED=0

log() { printf '[smoke-acl] %s\n' "$*"; }

# req TOKEN_VAR [curl args...]: curl con el token de esa variable en
# X-Consul-Token ("" = sin token, anonimo). El header sale de un descriptor
# para que el token no quede en la linea de comandos (ps) ni en la salida.
req() {
  local var="$1"
  shift
  if [[ -z $var ]]; then
    curl -sS "$@"
  else
    curl -sS -H @<(printf 'X-Consul-Token: %s\n' "${!var}") "$@"
  fi
}

# check DESCRIPCION ESPERADO OBTENIDO
check() {
  if [[ $3 == "$2" ]]; then
    log "ok    $1 -> $3"
  else
    log "FALLO $1 -> $3 (esperado $2)"
    FAILED=1
  fi
}

# register TOKEN_VAR NOMBRE: imprime el codigo HTTP de registrar NOMBRE.
register() {
  req "$1" -o /dev/null -w '%{http_code}' -X PUT "$CONSUL_URL/v1/agent/service/register" \
    --data "{\"ID\":\"$PREFIX-$2\",\"Name\":\"$2\"}"
}

# deregister TOKEN_VAR NOMBRE
deregister() {
  req "$1" -o /dev/null -w '%{http_code}' -X PUT "$CONSUL_URL/v1/agent/service/deregister/$PREFIX-$2"
}

cleanup() {
  local status=$?
  for name in extract documents traefik-falso anonimo; do
    deregister CONSUL_HTTP_TOKEN "$name" >/dev/null 2>&1 || true
  done
  if [[ $status -eq 0 ]]; then
    log "OK"
  else
    log "FALLO (exit $status)"
  fi
  exit "$status"
}
trap cleanup EXIT

log "1. sin token"
check "registrar extract sin token" 403 "$(register "" extract)"

log "2. token de extract"
check "registrar extract" 200 "$(register CONSUL_EXTRACT_TOKEN extract)"
check "desregistrar extract" 200 "$(deregister CONSUL_EXTRACT_TOKEN extract)"
check "registrar documents" 403 "$(register CONSUL_EXTRACT_TOKEN documents)"

log "3. token de documents"
check "registrar documents" 200 "$(register CONSUL_DOCUMENTS_TOKEN documents)"
check "desregistrar documents" 200 "$(deregister CONSUL_DOCUMENTS_TOKEN documents)"
check "registrar extract" 403 "$(register CONSUL_DOCUMENTS_TOKEN extract)"

log "4. token de Traefik"
check "leer /v1/catalog/services (incluye consul)" true \
  "$(req CONSUL_TRAEFIK_TOKEN -f "$CONSUL_URL/v1/catalog/services" | jq 'has("consul")')"
# health/service trae los datos del nodo: sin node:read saldria vacio.
check "leer /v1/health/service/consul (con nodo)" ds \
  "$(req CONSUL_TRAEFIK_TOKEN -f "$CONSUL_URL/v1/health/service/consul" | jq -r '.[0].Node.Node // "vacio"')"
check "registrar traefik-falso" 403 "$(register CONSUL_TRAEFIK_TOKEN traefik-falso)"

log "5. lectura anonima"
anon=$(req "" -w '\n%{http_code}' "$CONSUL_URL/v1/catalog/services")
check "codigo de /v1/catalog/services sin token" 200 "${anon##*$'\n'}"
check "servicios visibles sin token" 0 "$(jq 'length' <<<"${anon%$'\n'*}")"

log "6. agente"
check "policies del token del agente" agent \
  "$(req CONSUL_AGENT_TOKEN -f "$CONSUL_URL/v1/acl/token/self" | jq -r '[.Policies[].Name] | join(",")')"
# Sin token de agente valido el nodo queda sin TaggedAddresses (ver
# "Troubleshoot ACL" en la documentacion de Consul).
check "TaggedAddresses del nodo ds" true \
  "$(req CONSUL_TRAEFIK_TOKEN -f "$CONSUL_URL/v1/catalog/node/ds" | jq '.Node.TaggedAddresses.lan != null')"
init_id=$("${COMPOSE[@]}" ps -aq consul-acl-init)
[[ -n $init_id ]] || { log "FALLO no hay contenedor de consul-acl-init"; exit 1; }
init_state=$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$init_id")
check "consul-acl-init" "exited 0" "$init_state"
since="${SINCE:-$(docker inspect -f '{{.State.FinishedAt}}' "$init_id")}"
# Errores del propio agente: anti-entropy del nodo (token del agente) y de los
# servicios registrados en el agente (token con que se registro cada uno). Se
# excluye agent.http: son pedidos de clientes rechazados, como los 403 de este
# script.
agent_errors=$("${COMPOSE[@]}" logs --no-color --no-log-prefix --since "$since" consul 2>&1 \
  | grep -E '\[(ERROR|WARN) *\]' \
  | grep -v 'agent\.http:' \
  | grep -Ei 'acl|permission denied|blocked' || true)
if [[ -n $agent_errors ]]; then
  printf '%s\n' "$agent_errors" | sed 's/^/    /'
  if grep -q 'Service registration blocked' <<<"$agent_errors"; then
    log "pista: hay replicas registradas sin un token valido (por ejemplo, de antes"
    log "de deny). Recrearlas con su token (docker compose up -d --wait en su repo)."
  fi
fi
check "errores de ACL del agente desde $since" 0 "$(grep -c . <<<"$agent_errors" || true)"

((FAILED == 0))
