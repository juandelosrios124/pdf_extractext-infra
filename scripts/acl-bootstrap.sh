#!/bin/sh
# Bootstrap idempotente de las ACL de Consul (ver README, "ACL").
#
# Crea o actualiza:
#   - una policy por archivo de POLICIES_DIR (<nombre>.hcl -> policy <nombre>);
#   - un token por servicio (agent, traefik, extract, documents), con el
#     SecretID fijo que viene del entorno y solo la policy de su mismo nombre.
# Si ya existen los actualiza (reglas, descripcion y policies) en vez de
# duplicarlos: correrlo dos veces deja el mismo estado. Si un SecretID cambio
# (rotacion), crea el token nuevo y borra el anterior de ese servicio.
#
# Lo corre el servicio one-shot consul-acl-init del compose en cada
# "docker compose up" (POSIX sh: la imagen de Consul es Alpine, sin bash).
# A mano:
#   docker compose run --rm consul-acl-init
#
# Nunca imprime SecretIDs: la salida de la CLI que los contiene va a
# /dev/null y solo se muestran AccessorIDs.
#
# Entorno:
#   CONSUL_HTTP_ADDR    URL de Consul (la usa la CLI)
#   CONSUL_HTTP_TOKEN   token de management (initial_management)
#   CONSUL_AGENT_TOKEN, CONSUL_TRAEFIK_TOKEN, CONSUL_EXTRACT_TOKEN,
#   CONSUL_DOCUMENTS_TOKEN   SecretIDs (UUID) de cada token
#   POLICIES_DIR        directorio con las policies (default /policies)
#   WAIT_SECONDS        espera maxima a que el ACL este listo (default 60)

set -eu

POLICIES_DIR="${POLICIES_DIR:-/policies}"
WAIT_SECONDS="${WAIT_SECONDS:-60}"
SERVICES="agent traefik extract documents"
# Marca que identifica los tokens que maneja este script.
DESC_PREFIX="acl-bootstrap:"

log() { printf '[acl-bootstrap] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

: "${CONSUL_HTTP_TOKEN:?Falta CONSUL_HTTP_TOKEN (token de management)}"

is_uuid() {
  printf '%s' "$1" | grep -Eqi '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

# secret_of SERVICIO: valor de CONSUL_<SERVICIO>_TOKEN.
secret_of() {
  var="CONSUL_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')_TOKEN"
  eval "printf '%s' \"\${$var:-}\""
}

# Validaciones antes de tocar Consul: UUID, sin repetidos y distintos del de
# management (un token de servicio igual al de management lo degradaria).
seen="$CONSUL_HTTP_TOKEN"
for svc in $SERVICES; do
  secret=$(secret_of "$svc")
  var="CONSUL_$(printf '%s' "$svc" | tr '[:lower:]' '[:upper:]')_TOKEN"
  [ -n "$secret" ] || die "falta $var"
  is_uuid "$secret" || die "$var no es un UUID (generarlo con uuidgen)"
  for other in $seen; do
    [ "$secret" != "$other" ] || die "$var repite el valor de otro token"
  done
  seen="$seen $secret"
done

[ -d "$POLICIES_DIR" ] || die "no existe $POLICIES_DIR"

# El healthcheck de consul solo garantiza lider; initial_management se crea
# un instante despues en un volumen nuevo.
log "esperando el sistema de ACL en ${CONSUL_HTTP_ADDR:-127.0.0.1:8500}"
deadline=$(($(date +%s) + WAIT_SECONDS))
until consul acl token read -self >/dev/null 2>&1; do
  [ "$(date +%s)" -lt "$deadline" ] || die "el token de management no funciona tras ${WAIT_SECONDS}s"
  sleep 1
done

# --- Policies ---
for svc in $SERVICES; do
  file="$POLICIES_DIR/$svc.hcl"
  [ -f "$file" ] || die "falta la policy $file"
  desc="$DESC_PREFIX policy de $svc (consul/policies/$svc.hcl)"
  if consul acl policy read -name "$svc" >/dev/null 2>&1; then
    consul acl policy update -name "$svc" -description "$desc" -rules "@$file" >/dev/null
    log "policy $svc: actualizada"
  else
    consul acl policy create -name "$svc" -description "$desc" -rules "@$file" >/dev/null
    log "policy $svc: creada"
  fi
done

# --- Tokens ---
for svc in $SERVICES; do
  secret=$(secret_of "$svc")
  desc="$DESC_PREFIX token de $svc"
  # Buscar el token por su SecretID sin ponerlo en la linea de comandos:
  # "read -self" con el secret en el entorno de ese unico proceso.
  accessor=$(CONSUL_HTTP_TOKEN="$secret" consul acl token read -self -format=json 2>/dev/null \
    | jq -r '.AccessorID // empty') || accessor=""
  if [ -n "$accessor" ]; then
    # -policy-name reemplaza las policies del token (no las agrega). En la
    # CLI 2.0.4 el flag es -accessor-id (-id quedo como alias con aviso).
    consul acl token update -accessor-id "$accessor" -description "$desc" -policy-name "$svc" >/dev/null
    log "token $svc: actualizado (accessor $accessor)"
  else
    accessor=$(consul acl token create -secret "$secret" -description "$desc" \
      -policy-name "$svc" -format=json | jq -r '.AccessorID')
    log "token $svc: creado (accessor $accessor)"
  fi
  # Rotacion: otros tokens con la misma descripcion son de un SecretID viejo.
  consul acl token list -format=json \
    | jq -r --arg d "$desc" --arg a "$accessor" '.[] | select(.Description == $d and .AccessorID != $a) | .AccessorID' \
    | while read -r old; do
        consul acl token delete -accessor-id "$old" >/dev/null
        log "token $svc: borrado el anterior (accessor $old)"
      done
done

log "OK"
