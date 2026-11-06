#!/usr/bin/env bash
# Espera a que Traefik rutee extract y documents (target "wait-routes" del
# Makefile).
#
# "docker compose up --wait" espera el healthcheck de Docker, no el check de
# Consul: una replica entra en la rotacion de Traefik recien cuando su check
# pasa a passing (hasta un intervalo, 10 s). Este script espera, hasta
# ROUTES_TIMEOUT segundos, a que la API de Traefik muestre:
#   - los routers extract@consulcatalog y documents@consulcatalog habilitados;
#   - al menos un servidor en los services extract y documents (con
#     strictChecks=passing, solo aparecen las instancias passing).
#
# Variables:
#   TRAEFIK_API     API de Traefik (default http://127.0.0.1:8081)
#   ROUTES_TIMEOUT  segundos (default 60)
#   EXTRACT_DIR, DOCUMENTS_DIR  carpetas de los repos, solo para los mensajes

set -euo pipefail

TRAEFIK_API="${TRAEFIK_API:-http://127.0.0.1:8081}"
ROUTES_TIMEOUT="${ROUTES_TIMEOUT:-60}"
EXTRACT_DIR="${EXTRACT_DIR:-../extract-service}"
DOCUMENTS_DIR="${DOCUMENTS_DIR:-../documents-service}"
SERVICES=(extract documents)

log() { printf '[wait-routes] %s\n' "$*"; }

# servers NOMBRE: cantidad de servidores del service NOMBRE@consulcatalog
# (0 si no existe o Traefik no responde).
servers() {
  curl -fsS --max-time 3 "$TRAEFIK_API/api/http/services/$1@consulcatalog" 2>/dev/null \
    | jq '.loadBalancer.servers // [] | length' 2>/dev/null || echo 0
}

# missing: imprime lo que todavia falta, una cosa por linea.
missing() {
  local routers name n
  routers=$(curl -fsS --max-time 3 "$TRAEFIK_API/api/http/routers" 2>/dev/null) || {
    echo "la API de Traefik ($TRAEFIK_API)"
    return
  }
  for name in "${SERVICES[@]}"; do
    if ! jq -e --arg n "$name@consulcatalog" \
      'any(.[]; .name == $n and .status == "enabled")' <<<"$routers" >/dev/null; then
      echo "router $name@consulcatalog"
      continue
    fi
    n=$(servers "$name")
    ((n > 0)) || echo "servidores de $name"
  done
}

deadline=$((SECONDS + ROUTES_TIMEOUT))
last=""
while true; do
  pending=$(missing)
  if [[ -z $pending ]]; then
    summary=""
    for name in "${SERVICES[@]}"; do
      summary+="${summary:+, }$name ($(servers "$name") servidores)"
    done
    log "OK: Traefik rutea $summary"
    exit 0
  fi
  if ((SECONDS >= deadline)); then
    break
  fi
  if [[ $pending != "$last" ]]; then
    log "esperando: $(paste -sd, - <<<"$pending" | sed 's/,/, /g')"
    last=$pending
  fi
  sleep 2
done

log "FALLO: despues de ${ROUTES_TIMEOUT}s Traefik todavia no tiene:" >&2
while IFS= read -r item; do
  printf '[wait-routes]   - %s\n' "$item" >&2
done <<<"$pending"
if grep -q 'API de Traefik' <<<"$pending"; then
  log "Traefik no responde: revisar 'make ps' y 'make logs S=infra'." >&2
  exit 1
fi
cat >&2 <<EOF
[wait-routes] Causa mas probable: el servicio arranco healthy pero Consul rechazo
[wait-routes] su registro (403) porque CONSUL_HTTP_TOKEN de su .env esta vacio o
[wait-routes] no es el token de ese servicio (CONSUL_EXTRACT_TOKEN o
[wait-routes] CONSUL_DOCUMENTS_TOKEN del .env de infra). Correr 'make check' y
[wait-routes] buscar el 403 en los logs (la linea "No se pudo registrar" trae el error):
[wait-routes]   docker compose --project-directory $EXTRACT_DIR logs --no-color extract | grep 'No se pudo registrar'
[wait-routes]   docker compose --project-directory $DOCUMENTS_DIR logs --no-color documents | grep 'No se pudo registrar'
[wait-routes] Despues de corregir el .env: make up (recrea los contenedores con el token nuevo).
[wait-routes] Si recien arrancaron, puede faltar tiempo: ROUTES_TIMEOUT=120 make wait-routes
EOF
exit 1
