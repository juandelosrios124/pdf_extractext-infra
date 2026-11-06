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
#   7. "make -n up" (desarrollo): extract y documents con --build y sin -f.
#   8. "make -n up RELEASE=1": extract y documents con
#      -f <ruta absoluta>/docker-compose.yml, --pull=missing y sin --build;
#      infra igual que en desarrollo.
#   9. Tags: EXTRACT_IMAGE_TAG=sha-abc1234 en la linea de comandos llega solo a
#      extract. Exportado en el entorno (sin pasarlo a make) o vacio en la
#      linea de comandos no llega a ningun compose, y todos lo borran con
#      env -u (vale el .env de cada repo).
#  10. "make help" muestra RELEASE, RELEASE_UP_FLAGS, EXTRACT_IMAGE_TAG y
#      DOCUMENTS_IMAGE_TAG; RELEASE=0 y "make pull" sin RELEASE fallan.
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

# compose_line TEXTO DIR: la linea de "docker compose" con --project-directory
# "DIR" que no es el "config" de show_image (la de up, pull o down).
compose_line() {
  grep -F -- "--project-directory \"$2\"" <<<"$1" | grep -v ' config ' | head -n 1
}

# expect LINEA DESCRIPCION (has|lacks) TEXTO...: la linea tiene (o no) cada TEXTO.
expect() {
  local line=$1 what=$2 mode=$3 text
  shift 3
  for text in "$@"; do
    if [[ $mode == has ]] && ! grep -qF -- "$text" <<<"$line"; then
      fail "$what: falta \"$text\""
      return
    elif [[ $mode == lacks ]] && grep -qF -- "$text" <<<"$line"; then
      fail "$what: no deberia tener \"$text\""
      return
    fi
  done
  ok "$what: $mode $*"
}

log "7. make -n up (desarrollo)"
for repo in extract-service documents-service; do
  line=$(compose_line "$up" "$TMP/$repo")
  expect "$line" "$repo" has "up -d --build --wait"
  expect "$line" "$repo" lacks " -f " "--pull"
done

log "8. make -n up RELEASE=1"
release=$("${MAKE_CMD[@]}" -n up RELEASE=1 "${FAKE[@]}")
for repo in extract-service documents-service; do
  line=$(compose_line "$release" "$TMP/$repo")
  expect "$line" "$repo" has "-f \"$TMP/$repo/docker-compose.yml\" up -d --pull=missing --wait"
  expect "$line" "$repo" lacks "--build"
done
line=$(compose_line "$release" "$REPO_DIR")
expect "$line" "infra" has "up -d --wait"
expect "$line" "infra" lacks " -f " "--pull" "--build"
if grep -qF scripts/images.sh <<<"$release"; then
  ok "up RELEASE=1 termina con make images"
else
  fail "up RELEASE=1 no corre make images"
fi

log "9. tags de imagen"
tagged=$("${MAKE_CMD[@]}" -n up RELEASE=1 EXTRACT_IMAGE_TAG=sha-abc1234 "${FAKE[@]}")
expect "$(compose_line "$tagged" "$TMP/extract-service")" "extract con el tag" \
  has 'EXTRACT_IMAGE_TAG="sha-abc1234" docker compose'
expect "$(compose_line "$tagged" "$TMP/documents-service")" "documents sin el tag de extract" \
  lacks 'EXTRACT_IMAGE_TAG="' 'DOCUMENTS_IMAGE_TAG="'
expect "$(compose_line "$tagged" "$REPO_DIR")" "infra sin tags" \
  lacks 'EXTRACT_IMAGE_TAG="' 'DOCUMENTS_IMAGE_TAG="'
# El del entorno no se cuela: cada compose lo borra y ninguno lo vuelve a poner.
# Uno vacio en la linea de comandos tampoco (pisaria el .env con latest).
for case in "exportado" "vacio"; do
  if [[ $case == exportado ]]; then
    out=$(EXTRACT_IMAGE_TAG=x DOCUMENTS_IMAGE_TAG=y "${MAKE_CMD[@]}" -n up RELEASE=1 "${FAKE[@]}")
  else
    out=$("${MAKE_CMD[@]}" -n up RELEASE=1 EXTRACT_IMAGE_TAG= DOCUMENTS_IMAGE_TAG= "${FAKE[@]}")
  fi
  compose_lines=$(grep -c 'docker compose' <<<"$out" || true)
  unset_lines=$(grep 'docker compose' <<<"$out" \
    | grep -F -- '-u EXTRACT_IMAGE_TAG ' | grep -cF -- '-u DOCUMENTS_IMAGE_TAG ' || true)
  if ((compose_lines > 0 && compose_lines == unset_lines)) \
    && ! grep -qE '(EXTRACT|DOCUMENTS)_IMAGE_TAG="' <<<"$out"; then
    ok "tag $case: los $compose_lines docker compose lo borran y ninguno lo pasa"
  else
    fail "tag $case: docker compose $compose_lines, con env -u: $unset_lines"
    grep -E '(EXTRACT|DOCUMENTS)_IMAGE_TAG="' <<<"$out" | sed 's/^/    /' || true
  fi
done

log "10. help y errores del modo release"
help_release=$("${MAKE_CMD[@]}" help RELEASE=1 EXTRACT_IMAGE_TAG=sha-abc1234)
for var in RELEASE RELEASE_UP_FLAGS EXTRACT_IMAGE_TAG DOCUMENTS_IMAGE_TAG; do
  if grep -qE "^  $var +[^ ]" <<<"$help_release"; then
    ok "help muestra $var"
  else
    fail "help no muestra $var"
  fi
done
if grep -qE '^  EXTRACT_IMAGE_TAG +sha-abc1234$' <<<"$help_release"; then
  ok "help muestra el EXTRACT_IMAGE_TAG pasado"
else
  fail "help no muestra EXTRACT_IMAGE_TAG=sha-abc1234"
fi
if out=$("${MAKE_CMD[@]}" -n up RELEASE=0 "${FAKE[@]}" 2>&1); then
  fail "RELEASE=0 no fallo"
elif grep -qF 'RELEASE tiene que ser 1 o vacio' <<<"$out"; then
  ok "RELEASE=0 falla y dice que valores acepta"
else
  fail "RELEASE=0 falla sin explicar: $out"
fi
if out=$("${MAKE_CMD[@]}" pull "${FAKE[@]}" 2>&1); then
  fail "make pull sin RELEASE no fallo"
elif grep -qF 'correrlo con RELEASE=1' <<<"$out"; then
  ok "make pull sin RELEASE falla y pide RELEASE=1"
else
  fail "make pull sin RELEASE falla sin explicar: $out"
fi

if ((FAILED)); then
  log "FALLO"
  exit 1
fi
log "OK"
