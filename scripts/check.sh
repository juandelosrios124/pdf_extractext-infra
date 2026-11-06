#!/usr/bin/env bash
# Precondiciones de "make up" (target "check" del Makefile).
#
# Comprueba, sin levantar nada:
#   1. curl, jq y docker instalados; el daemon de Docker responde y Compose v2.
#   2. Las carpetas de infra, extract-service y documents-service existen y
#      tienen su compose.
#   3. Cada repo tiene su .env con CONSUL_HTTP_TOKEN no vacio; infra, ademas,
#      los otros cuatro tokens.
#   4. Los cinco tokens de infra son distintos, y el CONSUL_HTTP_TOKEN de
#      extract y el de documents son CONSUL_EXTRACT_TOKEN y
#      CONSUL_DOCUMENTS_TOKEN de infra. Si no, la replica arranca healthy pero
#      Consul rechaza su registro (403) y Traefik nunca la rutea.
#   5. En extract y documents, CONSUL_ENABLED no esta apagado; en documents,
#      EXTRACT_URL no apunta a localhost (dentro del contenedor es el propio
#      contenedor).
# Junta todos los errores y sale con 1 si hubo alguno; cada error dice que
# hacer.
#
# Nunca imprime tokens: los valores se leen en variables locales solo para
# compararlos. Los mensajes nombran la variable y el archivo, nunca el valor.
#
# Uso: scripts/check.sh INFRA_DIR EXTRACT_DIR DOCUMENTS_DIR

set -euo pipefail

if (($# != 3)); then
  echo "uso: $0 INFRA_DIR EXTRACT_DIR DOCUMENTS_DIR" >&2
  exit 2
fi
INFRA_DIR=$1
EXTRACT_DIR=$2
DOCUMENTS_DIR=$3

ERRORS=0

log() { printf '[check] %s\n' "$*"; }

# error MENSAJE [QUE HACER...]: registra un error y sigue.
error() {
  printf '[check] ERROR: %s\n' "$1" >&2
  shift
  local line
  for line in "$@"; do
    printf '[check]        %s\n' "$line" >&2
  done
  ERRORS=$((ERRORS + 1))
}

# env_value ARCHIVO VARIABLE: valor de VARIABLE en un .env, como lo interpreta
# Compose en los casos comunes (ultima definicion, "export" opcional, comillas
# simples o dobles, comentario al final). Solo se usa dentro de $(...) para
# comparar: el valor nunca se muestra.
env_value() {
  local line value
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?$2[[:space:]]*=" "$1" | tail -n 1) || true
  value=${line#*=}
  value=${value%$'\r'}
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  if ((${#value} >= 2)) && [[ $value == \"*\" || $value == \'*\' ]]; then
    value=${value:1:${#value}-2}
  else
    value=${value%%[[:space:]]#*}
  fi
  printf '%s' "$value"
}

# is_false VALOR: true si VALOR apaga un booleano (como lo leen los servicios).
is_false() {
  [[ ${1,,} =~ ^(false|0|no|off)$ ]]
}

# check_repo NOMBRE DIR VARIABLE_DIR: carpeta, compose y .env. Devuelve 1 si
# falta algo, para no seguir comparando tokens de un .env que no existe.
check_repo() {
  local name=$1 dir=$2 var=$3
  if [[ ! -d $dir ]]; then
    error "no existe la carpeta de $name: $dir" \
      "clonar el repo ahi o pasar $var=/ruta/a/$name (relativa a este repo o absoluta)"
    return 1
  fi
  if [[ ! -f $dir/docker-compose.yml && ! -f $dir/compose.yaml ]]; then
    error "$dir no tiene docker-compose.yml: no parece el repo de $name" \
      "revisar $var"
    return 1
  fi
  if [[ ! -f $dir/.env ]]; then
    error "falta $dir/.env" \
      "crearlo con: cp $dir/.env.example $dir/.env y completar CONSUL_HTTP_TOKEN"
    return 1
  fi
}

# require_token ARCHIVO VARIABLE QUE_VALOR: la variable existe y no esta vacia.
require_token() {
  if [[ -z $(env_value "$1" "$2") ]]; then
    error "$2 falta o esta vacio en $1" "$3"
    return 1
  fi
}

log "herramientas y Docker"
for tool in docker curl jq; do
  command -v "$tool" >/dev/null 2>&1 || error "no se encontro $tool" "instalarlo y volver a correr make check"
done
if command -v docker >/dev/null 2>&1; then
  if ! docker info >/dev/null 2>&1; then
    error "el daemon de Docker no responde" \
      "arrancarlo (sudo systemctl start docker) o revisar que el usuario este en el grupo docker"
  elif ! docker compose version >/dev/null 2>&1; then
    error "no esta el plugin docker compose (v2)" "instalar docker-compose-plugin"
  fi
fi

log "infra: $INFRA_DIR"
infra_ok=0
if check_repo infra "$INFRA_DIR" INFRA_DIR; then
  infra_ok=1
  infra_env=$INFRA_DIR/.env
  hint="generarlo con uuidgen (ver README, \"Generar los tokens\")"
  for var in CONSUL_HTTP_TOKEN CONSUL_AGENT_TOKEN CONSUL_TRAEFIK_TOKEN \
    CONSUL_EXTRACT_TOKEN CONSUL_DOCUMENTS_TOKEN; do
    require_token "$infra_env" "$var" "$hint" || infra_ok=0
  done
  if ((infra_ok)); then
    repeated=$(for var in CONSUL_HTTP_TOKEN CONSUL_AGENT_TOKEN CONSUL_TRAEFIK_TOKEN \
      CONSUL_EXTRACT_TOKEN CONSUL_DOCUMENTS_TOKEN; do
      env_value "$infra_env" "$var" | sha256sum
    done | sort | uniq -d | wc -l)
    if ((repeated > 0)); then
      error "hay tokens repetidos entre los cinco de $infra_env" \
        "cada uno tiene que ser un UUID distinto (uuidgen)"
      infra_ok=0
    fi
  fi
fi

# check_service NOMBRE DIR VARIABLE_DIR VARIABLE_EN_INFRA
check_service() {
  local name=$1 dir=$2 var=$3 infra_var=$4
  log "$name: $dir"
  check_repo "$name" "$dir" "$var" || return 0
  local env_file=$dir/.env
  local enabled
  enabled=$(env_value "$env_file" CONSUL_ENABLED)
  if is_false "$enabled"; then
    error "CONSUL_ENABLED esta apagado en $env_file" \
      "$name no se registraria en Consul y Traefik no lo rutearia." \
      "Borrar la linea (el compose usa true por defecto) o poner CONSUL_ENABLED=true"
  fi
  require_token "$env_file" CONSUL_HTTP_TOKEN \
    "poner CONSUL_HTTP_TOKEN=<valor de $infra_var del .env de infra>" || return 0
  ((infra_ok)) || return 0
  if [[ $(env_value "$env_file" CONSUL_HTTP_TOKEN) != "$(env_value "$INFRA_DIR/.env" "$infra_var")" ]]; then
    error "el CONSUL_HTTP_TOKEN de $env_file no es el $infra_var del .env de infra" \
      "$name arrancaria healthy, pero Consul rechazaria su registro (403) y Traefik no lo rutearia." \
      "Copiar el valor de $infra_var de $INFRA_DIR/.env como CONSUL_HTTP_TOKEN en $env_file"
  fi
}

check_service extract-service "$EXTRACT_DIR" EXTRACT_DIR CONSUL_EXTRACT_TOKEN
check_service documents-service "$DOCUMENTS_DIR" DOCUMENTS_DIR CONSUL_DOCUMENTS_TOKEN

if [[ -f $DOCUMENTS_DIR/.env ]]; then
  extract_url=$(env_value "$DOCUMENTS_DIR/.env" EXTRACT_URL)
  if [[ $extract_url =~ ^https?://(localhost|127\.0\.0\.1)([:/]|$) ]]; then
    error "EXTRACT_URL apunta a localhost en $DOCUMENTS_DIR/.env" \
      "dentro del contenedor localhost es el propio contenedor de documents." \
      "Borrar la linea (el compose usa http://traefik por defecto); localhost solo sirve con uv run"
  fi
fi

if ((ERRORS > 0)); then
  log "FALLO: $ERRORS error(es)"
  exit 1
fi
log "OK"
