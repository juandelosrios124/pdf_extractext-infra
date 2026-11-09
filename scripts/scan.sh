#!/usr/bin/env bash
# Escaneo de vulnerabilidades con Grype (target "scan" del Makefile y job
# "scan" de la CI, issue #15).
#
# Dos modos:
#
#   scripts/scan.sh SERVICIO DIR [SERVICIO DIR ...]
#       Lo que esta corriendo. La lista sale de "scripts/images.sh --list", la
#       misma de "make images": se escanea la imagen que el contenedor corre de
#       verdad, no lo que hoy apunta el tag.
#
#   scripts/scan.sh --images IMAGEN [IMAGEN ...]
#       Las imagenes que se le pasan, sin tener que levantar nada. La CI le
#       pasa "docker compose config --images", asi la lista no se desincroniza
#       de lo que esta fijado en el compose.
#
# Grype corre como contenedor con la version fijada (GRYPE_IMAGE) y *sin montar
# docker.sock*: darle el socket al escaner es darle control del daemon. Por eso
# no se usa el esquema "docker:" de Grype, que necesita el socket. En su lugar:
#
#   - imagen con digest (el del registry, o el "@sha256:..." con el que el
#     compose la fija) -> "registry:<repo>@<digest>", que Grype baja por su
#     cuenta y es exactamente la que corre el contenedor;
#   - imagen construida en la maquina (<repo>:dev, sin digest por ningun lado)
#     -> "docker save" a un tar y "docker-archive:", montado solo lectura.
#
# La base de vulnerabilidades se guarda en un volumen (GRYPE_DB_VOLUME): son
# cientos de MB y bajarla una vez por imagen no tiene sentido.
#
# Informativo: no falla por hallazgos. Las imagenes que escanea la CI son de
# terceros y no se parchean, solo se sube la version (ver "Escaneo de imagenes"
# en el README). Si Grype no llega a escanear una imagen, lo dice, sigue con las
# demas y al final sale con 1: eso es un problema del escaneo, no un hallazgo.
#
# La salida es Markdown: se lee igual en la terminal y la CI la pega tal cual
# en $GITHUB_STEP_SUMMARY.

set -euo pipefail

# Version fijada: el resultado no cambia porque salio un escaner nuevo.
GRYPE_IMAGE=${GRYPE_IMAGE:-anchore/grype:v0.121.2}
# Volumen con la base de vulnerabilidades (lo crea Docker en el primer uso).
GRYPE_DB_VOLUME=${GRYPE_DB_VOLUME:-grype-db}
# Cuantos critical/high se listan por imagen. Consul trae casi cien y taparian
# el resumen; la tabla de severidades los cuenta todos igual.
MAX_MATCHES=${MAX_MATCHES:-20}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  cat >&2 <<'USAGE'
uso: scripts/scan.sh SERVICIO DIR [SERVICIO DIR ...]   (lo que esta corriendo)
     scripts/scan.sh --images IMAGEN [IMAGEN ...]      (imagenes del compose)
USAGE
}

mode=running
if [[ ${1-} == --images ]]; then
  mode=images
  shift
fi
if (($# == 0)) || { [[ $mode == running ]] && (($# % 2 != 0)); }; then
  usage
  exit 2
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Objetivos a escanear, en arrays paralelos: que servicio lo corre (vacio en
# modo --images), la imagen a mostrar, el esquema de Grype y la referencia.
t_svc=() t_img=() t_src=() t_ref=()

# add_target SERVICIO IMAGEN ORIGEN REF: agrega un objetivo. Si la referencia
# ya esta (consul y consul-acl-init comparten imagen), solo suma el servicio.
add_target() {
  local i
  for i in "${!t_ref[@]}"; do
    if [[ ${t_ref[i]} == "$4" && ${t_src[i]} == "$3" ]]; then
      if [[ -n $1 ]]; then
        t_svc[i]="${t_svc[i]:+${t_svc[i]}, }$1"
      fi
      return 0
    fi
  done
  t_svc+=("$1") t_img+=("$2") t_src+=("$3") t_ref+=("$4")
}

if [[ $mode == images ]]; then
  for image in "$@"; do
    add_target "" "$image" registry "$image"
  done
else
  # images.sh --list: SERVICIO<TAB>IMAGEN<TAB>ID<TAB>DIGEST. El digest es el del
  # registry (RepoDigests) y solo viene para imagenes con host de registry
  # (ghcr.io/...). Traefik, Consul y Mongo no tienen host, pero el compose las
  # fija con "@sha256:...": esa referencia ya alcanza para "registry:". Lo que
  # queda sin digest por los dos lados es un build local (<repo>:dev), y va por
  # "docker save".
  while IFS=$'\t' read -r service image id digest; do
    if [[ -n $digest ]]; then
      add_target "$service" "$image" registry "$digest"
    elif [[ $image == *@sha256:* ]]; then
      add_target "$service" "$image" registry "$image"
    else
      add_target "$service" "$image" docker-archive "$id"
    fi
  done < <("$SCRIPT_DIR/images.sh" --list "$@")
fi

if ((${#t_ref[@]} == 0)); then
  echo "### Escaneo de imagenes (Grype)"
  echo
  echo "Sin imagenes para escanear: no hay contenedores corriendo."
  exit 0
fi

# host_path RUTA: la ruta como la ve el daemon de Docker. En Git Bash hay que
# traducirla ("/tmp/x" -> "C:/Users/.../Temp/x"); en Linux y mac no cambia.
host_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s' "$1"
  fi
}

# run_grype ARG...: Grype en un contenedor, con el volumen de la base de
# vulnerabilidades y sin docker.sock. MSYS_NO_PATHCONV y MSYS2_ARG_CONV_EXCL:
# en Git Bash los argumentos que parecen rutas absolutas se convierten a rutas
# de Windows ("/cache" -> "C:/Program Files/Git/cache"), y estas son rutas de
# dentro del contenedor; en Linux y mac las dos variables no hacen nada.
run_grype() {
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker run --rm -q \
    -e GRYPE_DB_CACHE_DIR=/cache -v "$GRYPE_DB_VOLUME:/cache" "$@"
}

# scan_target ORIGEN REF REPORTE ARCHIVO: deja el JSON de Grype en REPORTE.
# ARCHIVO es el tar de este objetivo (uno por objetivo, asi un fallo no
# contamina al siguiente). Se llama dentro de un "if !", donde bash ignora
# "set -e": cada paso que puede fallar corta con "|| return" a mano.
scan_target() {
  local src=$1 ref=$2 report=$3 tar=$4 gerr="$4.grype.err" rc=0
  case $src in
    registry)
      run_grype "$GRYPE_IMAGE" -q -o json "registry:$ref" >"$report" 2>"$gerr" || rc=$?
      ;;
    docker-archive)
      # El tar sale de la imagen por ID (la que corre el contenedor) y se monta
      # solo lectura: Grype no necesita nada mas del daemon. Si docker save
      # falla no se lanza Grype: "docker run -v" sobre un archivo que no existe
      # crea un directorio en su lugar.
      if ! docker save --output "$tar" "$ref"; then
        rm -rf "$tar"
        echo "docker save no pudo exportar $ref: la imagen que corre el contenedor ya no esta en el daemon (se reconstruyo o se borro el tag?). Recrear el contenedor y volver a correr el escaneo." >&2
        return 1
      fi
      run_grype -v "$(host_path "$tar"):/image.tar:ro" \
        "$GRYPE_IMAGE" -q -o json docker-archive:/image.tar >"$report" 2>"$gerr" || rc=$?
      rm -rf "$tar"
      ;;
  esac
  if ((rc != 0)); then
    echo "Grype termino con codigo $rc. Salida de error:" >&2
    tail -n 20 "$gerr" >&2
    return 1
  fi
}

# severity_table REPORTE: hallazgos por severidad, y cuantos tienen fix (los
# unicos sobre los que se puede hacer algo: subir la version de la imagen).
severity_table() {
  echo "| Severidad | Hallazgos | Con fix |"
  echo "|---|---|---|"
  jq -r '
    (.matches // []) as $m
    | ["Critical", "High", "Medium", "Low", "Negligible", "Unknown"][]
    | . as $s
    | [$m[] | select((.vulnerability.severity // "Unknown") == $s)] as $sev
    | "| \($s) | \($sev | length) | \([$sev[] | select(.vulnerability.fix.state == "fixed")] | length) |"
  ' "$1"
}

# top_matches REPORTE: una linea por hallazgo critical o high.
top_matches() {
  jq -r '
    [(.matches // [])[] | select((.vulnerability.severity // "") == "Critical"
        or (.vulnerability.severity // "") == "High")]
    | sort_by(.vulnerability.severity, .artifact.name)[]
    | "- \(.vulnerability.severity) `\(.vulnerability.id)` \(.artifact.name) \(.artifact.version)"
      + (if (.vulnerability.fix.versions // []) | length > 0
         then " -> fix en \((.vulnerability.fix.versions | join(", ")))"
         else " (sin fix)" end)
  ' "$1"
}

echo "### Escaneo de imagenes (Grype \`$GRYPE_IMAGE\`)"
echo
if [[ $mode == images ]]; then
  echo "Imagenes de terceros del compose de infra: no se parchean, se sube la version."
  echo "Informativo, no corta la CI (ver README, \"Escaneo de imagenes\")."
else
  echo "Lo que esta corriendo en los tres stacks. Informativo: no falla por hallazgos."
fi
echo

failed=0
for i in "${!t_ref[@]}"; do
  report="$TMP/report-$i.json"
  echo "#### ${t_svc[i]:+${t_svc[i]}: }\`${t_img[i]}\`"
  echo
  if [[ ${t_src[i]} == registry ]]; then
    echo "Escaneado por digest del registry: \`${t_ref[i]}\`"
  else
    echo "Sin digest para bajarla del registry: \`docker save\` de \`${t_ref[i]}\` y \`docker-archive:\`"
  fi
  echo
  if ! scan_target "${t_src[i]}" "${t_ref[i]}" "$report" "$TMP/image-$i.tar" 2>"$TMP/error.txt"; then
    echo "**Grype no pudo escanear esta imagen:**"
    echo
    echo '```'
    tail -n 20 "$TMP/error.txt"
    echo '```'
    echo
    failed=1
    continue
  fi
  severity_table "$report"
  echo
  top_matches "$report" >"$TMP/top.txt"
  if [[ -s "$TMP/top.txt" ]]; then
    head -n "$MAX_MATCHES" "$TMP/top.txt"
    resto=$(($(wc -l <"$TMP/top.txt") - MAX_MATCHES))
    if ((resto > 0)); then
      echo "- ... y $resto hallazgos critical o high mas (los cuenta la tabla de arriba)"
    fi
  else
    echo "Sin hallazgos critical ni high."
  fi
  echo
done

if ((failed)); then
  echo "Alguna imagen no se pudo escanear (ver arriba)." >&2
  exit 1
fi
