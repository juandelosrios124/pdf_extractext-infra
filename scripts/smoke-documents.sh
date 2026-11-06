#!/usr/bin/env bash
# Smoke test de punta a punta (target "smoke" del Makefile), con un PDF real:
#
#   1. POST /extract por Traefik -> 200 con page_count > 0. No guarda nada y
#      prueba extract aunque el paso 2 sea un duplicado (que no lo llama).
#   2. POST /documents por Traefik -> 201 (documento nuevo) o 200 con
#      "duplicate": true (ya estaba guardado). El pedido entra por Traefik,
#      pasa por documents, vuelve a entrar por Traefik hacia extract (si es
#      nuevo) y se guarda en Mongo.
#
# Muestra el id, el archivo, las paginas y si fue duplicado; nunca el
# contenido extraido. Los dos pedidos llevan el mismo X-Request-ID, para
# seguirlos en los logs.
#
# Uso: scripts/smoke-documents.sh PDF
# Variables: TRAEFIK_URL (default http://127.0.0.1:8080)

set -euo pipefail

if (($# != 1)); then
  echo "uso: $0 PDF" >&2
  exit 2
fi
PDF=$1
TRAEFIK_URL="${TRAEFIK_URL:-http://127.0.0.1:8080}"
REQUEST_ID="smoke-make-$$-$(date +%s)"

log() { printf '[smoke-documents] %s\n' "$*"; }

[[ -f $PDF ]] || { log "FALLO: no existe el PDF $PDF (SMOKE_PDF)" >&2; exit 1; }

body=$(mktemp)
trap 'rm -f "$body"' EXIT

# post RUTA [curl args...]: imprime el codigo HTTP y deja el cuerpo en $body.
# 35 s: por encima del presupuesto de timeouts del cliente (30 s).
post() {
  local path=$1
  shift
  curl -sS -o "$body" -w '%{http_code}' --max-time 35 \
    -H "X-Request-ID: $REQUEST_ID" "$@" "$TRAEFIK_URL$path" || {
    log "FALLO: curl no obtuvo respuesta de $path (exit $?)" >&2
    return 1
  }
}

# fail_http CODIGO: muestra el error (el detail, no el contenido) y sale.
fail_http() {
  log "FALLO: HTTP $1 $(jq -c '.detail // .' "$body" 2>/dev/null || head -c 300 "$body")" >&2
  log "seguir el pedido: grep $REQUEST_ID en 'make logs S=documents' y 'make logs S=extract'" >&2
  exit 1
}

log "X-Request-ID: $REQUEST_ID, PDF: $(basename "$PDF")"

log "1. POST $TRAEFIK_URL/extract"
code=$(post /extract -H 'Content-Type: application/pdf' --data-binary "@$PDF")
[[ $code == 200 ]] || fail_http "$code"
pages=$(jq -r '.page_count // 0' "$body")
chars=$(jq -r '.content // "" | length' "$body")
((pages > 0)) || { log "FALLO: 200 sin page_count" >&2; exit 1; }
log "OK: 200, $pages paginas, $chars caracteres"

log "2. POST $TRAEFIK_URL/documents"
code=$(post /documents -F "file=@$PDF;type=application/pdf")
summary=$(jq -c '{id, filename, page_count, duplicate}' "$body" 2>/dev/null || true)
case $code in
  201)
    log "OK: 201 $summary"
    ;;
  200)
    if jq -e '.duplicate == true' "$body" >/dev/null 2>&1; then
      log "OK: 200 duplicate $summary"
    else
      log "FALLO: 200 sin \"duplicate\": true" >&2
      exit 1
    fi
    ;;
  *)
    fail_http "$code"
    ;;
esac
