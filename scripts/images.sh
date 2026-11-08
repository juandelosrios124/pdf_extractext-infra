#!/usr/bin/env bash
# Que imagen corre cada servicio (target "images" del Makefile, issue #13).
#
# Para cada SERVICIO, toma sus contenedores corriendo en el proyecto de Compose
# de DIR y muestra una linea por imagen distinta (no por replica):
#   - la imagen configurada (ghcr.io/...:sha-xxxxxxx o <repo>:dev);
#   - el digest del registry (RepoDigests), que identifica la imagen aunque el
#     tag se mueva;
#   - el label org.opencontainers.image.revision (el commit que construyo la CI).
# Si las replicas de un servicio corren imagenes distintas (por ejemplo, un
# "latest" que se refresco a mitad de camino), sale una linea por cada una.
#
# Se mira la imagen por ID, la que el contenedor corre de verdad, no lo que hoy
# apunta el tag. Un build local (sin host de registry, como extract-service:dev)
# no tiene un digest que sirva para reproducir la corrida: con el image store
# de containerd tiene RepoDigests, pero son de la maquina. Sale "build local,
# sin digest".
#
# Con --list no imprime la tabla: una linea por imagen distinta con
# "SERVICIO<TAB>IMAGEN<TAB>ID<TAB>DIGEST" (DIGEST vacio si la imagen no viene de
# un registry), para que otro script la consuma. La usa scripts/scan.sh (#15).
#
# Uso: scripts/images.sh [--list] SERVICIO DIR [SERVICIO DIR ...]

set -euo pipefail

# --list: salida para otro script (scripts/scan.sh), no la tabla.
list_only=false
if [[ ${1-} == --list ]]; then
  list_only=true
  shift
fi

if (($# == 0 || $# % 2 != 0)); then
  echo "uso: $0 [--list] SERVICIO DIR [SERVICIO DIR ...]" >&2
  exit 2
fi

# from_registry IMAGEN: true si el primer componente es un host de registry
# (ghcr.io, localhost:5000), como lo distingue Docker.
from_registry() {
  local first=${1%%/*}
  [[ $1 == */* && ($first == *.* || $first == *:* || $first == localhost) ]]
}

# repo_of IMAGEN: IMAGEN sin el tag ni el digest.
repo_of() {
  local repo=${1%@*} last
  last=${repo##*/}
  if [[ $last == *:* ]]; then
    repo=${repo%:*}
  fi
  printf '%s' "$repo"
}

while (($# > 0)); do
  service=$1 dir=$2
  shift 2
  mapfile -t ids < <(docker compose --project-directory "$dir" ps -q "$service")
  if ((${#ids[@]} == 0)); then
    if $list_only; then
      printf 'sin contenedores corriendo: %s (%s)\n' "$service" "$dir" >&2
    else
      printf '%-10s sin contenedores corriendo (%s)\n' "$service" "$dir"
    fi
    continue
  fi
  # "imagen configurada<TAB>ID de imagen", contado por par distinto.
  while read -r count image id; do
    replicas="$count replica$( ((count == 1)) || echo s)"
    digest=""
    revision=""
    if from_registry "$image"; then
      meta=$(docker image inspect "$id" | jq -r --arg repo "$(repo_of "$image")" '.[0] |
        ([.RepoDigests[]? | select(startswith($repo + "@"))][0] // ""),
        (.Config.Labels["org.opencontainers.image.revision"] // "sin label")')
      digest=$(sed -n 1p <<<"$meta")
      revision=$(sed -n 2p <<<"$meta")
    fi
    if $list_only; then
      printf '%s\t%s\t%s\t%s\n' "$service" "$image" "$id" "$digest"
    elif ! from_registry "$image"; then
      printf '%-10s %-11s %s  build local, sin digest\n' "$service" "$replicas" "$image"
    else
      printf '%-10s %-11s %s  digest %s  revision %s\n' \
        "$service" "$replicas" "$image" "${digest:-sin digest}" "$revision"
    fi
  done < <(docker inspect --format '{{.Config.Image}} {{.Image}}' "${ids[@]}" | sort | uniq -c)
done
