#!/usr/bin/env bash
# Tests del Makefile que no necesitan los otros repos ni levantar nada (los
# corre la CI). Usa carpetas temporales con un .env de prueba; nunca lee los
# .env reales de extract-service ni de documents-service.
#
#   1. "make help" lista todos los targets .PHONY.
#   2. "make -n up": check -> network -> infra -> extract -> documents ->
#      wait-routes.
#   3. Con CONSUL_HTTP_TOKEN exportado, cada "docker compose" de "make -n up"
#      corre con "env -u CONSUL_HTTP_TOKEN", y el Makefile no exporta nada.
#   4. "make -n down": documents -> extract -> infra, sin -v.
#   5. "make check DOCUMENTS_DIR=/no/existe" falla y lo dice.
#   6. "make check" con CONSUL_HTTP_TOKEN= vacio en el .env de extract falla y
#      dice que falta y donde.
#
# Uso: scripts/test-makefile.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAKE_CMD=(make --no-print-directory -C "$REPO_DIR")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILED=0

log() { printf '[test-makefile] %s\n' "$*"; }
ok() { log "ok    $*"; }
fail() {
  log "FALLO $*"
  FAILED=1
}

# Repos de prueba: compose vacio y .env sin token.
for repo in extract-service documents-service; do
  mkdir -p "$TMP/$repo"
  : >"$TMP/$repo/docker-compose.yml"
  printf 'CONSUL_HTTP_TOKEN=\n' >"$TMP/$repo/.env"
done
FAKE=(EXTRACT_DIR="$TMP/extract-service" DOCUMENTS_DIR="$TMP/documents-service")

# in_order TEXTO PATRON...: los patrones aparecen en TEXTO en ese orden.
in_order() {
  local text=$1 line prev=0 pattern
  shift
  for pattern in "$@"; do
    line=$(grep -nF -- "$pattern" <<<"$text" | head -n 1 | cut -d: -f1)
    if [[ -z $line ]] || ((line <= prev)); then
      echo "\"$pattern\" falta o esta fuera de orden"
      return 1
    fi
    prev=$line
  done
}

log "1. make help"
help=$("${MAKE_CMD[@]}" help)
phony=$(sed -n 's/^\.PHONY:[[:space:]]*//p' "$REPO_DIR/Makefile")
for target in $phony; do
  if grep -qE "^  $target +[^ ]" <<<"$help"; then
    ok "help lista $target"
  else
    fail "help no lista $target"
  fi
done

log "2. make -n up"
up=$("${MAKE_CMD[@]}" -n up "${FAKE[@]}")
if why=$(in_order "$up" scripts/check.sh "docker network" \
  "\"$REPO_DIR\" up -d --wait" \
  "\"$TMP/extract-service\" up -d --build --wait" \
  "\"$TMP/documents-service\" up -d --build --wait" \
  scripts/wait-routes.sh); then
  ok "orden: check, network, infra, extract, documents, wait-routes"
else
  fail "orden de up: $why"
fi

log "3. CONSUL_HTTP_TOKEN exportado"
up_env=$(CONSUL_HTTP_TOKEN=cualquiera "${MAKE_CMD[@]}" -n up "${FAKE[@]}")
compose_lines=$(grep -c 'docker compose' <<<"$up_env" || true)
clean_lines=$(grep 'docker compose' <<<"$up_env" | grep -c 'env -u CONSUL_HTTP_TOKEN ' || true)
if ((compose_lines == 3 && clean_lines == 3)); then
  ok "los 3 docker compose corren con env -u CONSUL_HTTP_TOKEN"
else
  fail "docker compose: $compose_lines, con env -u CONSUL_HTTP_TOKEN: $clean_lines"
fi
if grep -qE '^[[:space:]]*(export|unexport)\b|^\.EXPORT_ALL_VARIABLES' "$REPO_DIR/Makefile"; then
  fail "el Makefile exporta variables"
else
  ok "el Makefile no exporta variables"
fi

log "4. make -n down"
down=$("${MAKE_CMD[@]}" -n down "${FAKE[@]}")
if why=$(in_order "$down" "\"$TMP/documents-service\" down" \
  "\"$TMP/extract-service\" down" "\"$REPO_DIR\" down"); then
  ok "orden: documents, extract, infra"
else
  fail "orden de down: $why"
fi
if grep -E 'docker compose.* down' <<<"$down" | grep -qE ' (-v|--volumes)\b'; then
  fail "down usa -v"
else
  ok "down sin -v"
fi

# expect_check_fails DESCRIPCION MENSAJE [VARIABLE=valor...]
expect_check_fails() {
  local what=$1 message=$2 out
  shift 2
  if out=$("${MAKE_CMD[@]}" check "$@" 2>&1); then
    fail "$what: make check no fallo"
  elif grep -qF -- "$message" <<<"$out"; then
    ok "$what: falla con \"$message\""
  else
    fail "$what: falla sin el mensaje \"$message\""
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

log "5. make check con una carpeta que no existe"
expect_check_fails "DOCUMENTS_DIR=/no/existe" \
  "no existe la carpeta de documents-service: /no/existe" \
  EXTRACT_DIR="$TMP/extract-service" DOCUMENTS_DIR=/no/existe

log "6. make check con CONSUL_HTTP_TOKEN vacio"
expect_check_fails ".env de prueba sin token" \
  "CONSUL_HTTP_TOKEN falta o esta vacio en $TMP/extract-service/.env" "${FAKE[@]}"

if ((FAILED)); then
  log "FALLO"
  exit 1
fi
log "OK"
