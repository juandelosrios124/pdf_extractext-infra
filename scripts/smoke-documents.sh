#!/usr/bin/env bash
# Smoke test de punta a punta (target "smoke" del Makefile): POST /documents
# por Traefik con un PDF real. El pedido entra por Traefik, pasa por
# documents, vuelve a entrar por Traefik hacia extract y se guarda en Mongo.
#
# Acepta 201 (documento nuevo) o 200 con "duplicate": true (ya estaba
# guardado: documents no vuelve a llamar a extract). Muestra el id, el archivo,
# las paginas y si fue duplicado; nunca el contenido extraido.
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

log "POST $TRAEFIK_URL/documents con $(basename "$PDF") (X-Request-ID: $REQUEST_ID)"
# 35 s: por encima del presupuesto de timeouts del cliente (30 s).
code=$(curl -sS -o "$body" -w '%{http_code}' --max-time 35 \
  -H "X-Request-ID: $REQUEST_ID" \
  -F "file=@$PDF;type=application/pdf" \
  "$TRAEFIK_URL/documents") || {
  log "FALLO: curl no obtuvo respuesta (exit $?)" >&2
  exit 1
}

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
    log "FALLO: HTTP $code $(jq -c '.detail // .' "$body" 2>/dev/null || head -c 300 "$body")" >&2
    log "seguir el pedido: grep $REQUEST_ID en 'make logs S=documents' y 'make logs S=extract'" >&2
    exit 1
    ;;
esac
