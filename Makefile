# Levanta el sistema completo en orden: red compartida -> infra (Consul,
# consul-acl-init y Traefik) -> extract-service -> documents-service, y espera
# a que Traefik rutee los dos servicios (issue #6, 12-Factor X).
# "make" solo muestra la ayuda. Ver README, "Levantar el sistema completo".
#
# Cada stack se maneja con "docker compose --project-directory <repo>": usa el
# .env de su propio repo y el nombre de proyecto de siempre (el nombre de la
# carpeta), asi que "make down" baja lo que se levanto a mano y viceversa.
#
# Dos modos para extract y documents (issue #13, 12-Factor V):
#   make up               desarrollo: compila la carpeta (override, <repo>:dev)
#   make up RELEASE=1 EXTRACT_IMAGE_TAG=sha-xxxxxxx DOCUMENTS_IMAGE_TAG=sha-yyyyyyy
#                         release: las imagenes que publico la CI en GHCR

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
# El orden de los pasos importa: nunca en paralelo, aunque se pase -j.
.NOTPARALLEL:
MAKEFLAGS += --no-builtin-rules --no-print-directory

# --- Configurables (make up VARIABLE=valor) ---------------------------------
# Rutas relativas a este repo (no al directorio desde donde se corre make).
EXTRACT_DIR ?= ../extract-service
DOCUMENTS_DIR ?= ../documents-service
# Red externa compartida. Se le pasa a los tres compose, asi la red que se crea
# es la misma que usan.
SHARED_NETWORK ?= mired
# Segundos que wait-routes espera a que Traefik rutee extract y documents.
ROUTES_TIMEOUT ?= 60
# Traefik publicado por infra (TRAEFIK_PORT y TRAEFIK_DASHBOARD_PORT).
TRAEFIK_URL ?= http://127.0.0.1:8080
TRAEFIK_API ?= http://127.0.0.1:8081
# Flags de "docker compose up" de cada stack en modo desarrollo. Cambiar
# --build por --pull=missing NO alcanza para usar las imagenes de GHCR: sin -f,
# Compose siempre lee docker-compose.override.yml, que agrega "build: ." e
# "image: <repo>:dev". Para eso esta RELEASE=1.
INFRA_UP_FLAGS ?= -d --wait
EXTRACT_UP_FLAGS ?= -d --build --wait
DOCUMENTS_UP_FLAGS ?= -d --build --wait
# Vacio: desarrollo. 1: release, extract y documents con
# -f <repo>/docker-compose.yml (sin el override, sin build) y RELEASE_UP_FLAGS
# en lugar de EXTRACT_UP_FLAGS y DOCUMENTS_UP_FLAGS. Infra es igual en los dos.
RELEASE ?=
# missing y no always: un sha-xxxxxxx o un vX.Y.Z es inmutable, asi que
# bajarlo una vez alcanza y no hace falta ir a GHCR en cada "up". La contra es
# "latest": si ya esta en la maquina no se vuelve a bajar, y para refrescarlo
# hay que hacer "make pull RELEASE=1".
RELEASE_UP_FLAGS ?= -d --pull=missing --wait
# EXTRACT_IMAGE_TAG y DOCUMENTS_IMAGE_TAG (sha-xxxxxxx, vX.Y.Z o latest): solo
# con RELEASE=1 y solo si se pasan en la linea de comandos con un valor. Si no,
# vale el del .env de cada repo, y si tampoco esta, latest. Ver COMPOSE_UNSET.
# make logs S=infra|extract|documents
S ?= documents
TAIL ?= 100
# PDF de make smoke (por defecto, uno del set de pruebas de carga de extract).
SMOKE_PDF ?= $(EXTRACT)/tests/stress/pdfs/2020-Scrum-Guide-Spanish-Latin-South-American.pdf

# --- Internas ---------------------------------------------------------------
MAKEFILE_PATH := $(abspath $(lastword $(MAKEFILE_LIST)))
INFRA_DIR := $(patsubst %/,%,$(dir $(MAKEFILE_PATH)))
resolve = $(abspath $(if $(filter /%,$(1)),$(1),$(INFRA_DIR)/$(1)))
EXTRACT = $(call resolve,$(EXTRACT_DIR))
DOCUMENTS = $(call resolve,$(DOCUMENTS_DIR))

# Compose le da prioridad al entorno del shell sobre el .env: un
# CONSUL_HTTP_TOKEN exportado pisaria el token de cada repo y el servicio
# quedaria sin registrarse (403). Por eso no hay "export" en este Makefile, y
# los comandos de Compose y de los smoke corren sin estas variables; cada repo
# las toma de su .env. COMPOSE_PROJECT_NAME y COMPOSE_FILE, para que el
# proyecto sea siempre el de la carpeta.
#
# EXTRACT_IMAGE_TAG y DOCUMENTS_IMAGE_TAG tambien: un tag exportado en la
# terminal (de otra medicion) cambiaria la imagen sin que aparezca en el
# comando. Ademas, Make pasa al entorno de las recetas las variables de la
# linea de comandos aunque esten vacias, y un EXTRACT_IMAGE_TAG= vacio pisaria
# el .env y dejaria latest. Se borran siempre, y release_env vuelve a poner
# solo los que se pasaron a make con un valor ($(origin) "command line").
COMPOSE_UNSET := CONSUL_HTTP_TOKEN CONSUL_AGENT_TOKEN CONSUL_TRAEFIK_TOKEN \
	CONSUL_EXTRACT_TOKEN CONSUL_DOCUMENTS_TOKEN CONSUL_HTTP_ADDR CONSUL_ENABLED \
	COMPOSE_PROJECT_NAME COMPOSE_FILE EXTRACT_IMAGE_TAG DOCUMENTS_IMAGE_TAG
CLEAN_ENV = env $(addprefix -u ,$(COMPOSE_UNSET)) SHARED_NETWORK="$(SHARED_NETWORK)"
# $(call compose,DIR): docker compose del repo en DIR, con el override si lo
# tiene. Es el de infra, y el de down, ps y logs en los dos modos: Compose
# encuentra los contenedores por el nombre del proyecto (la carpeta, con -f o
# sin -f) y el de los servicios, que son los mismos con o sin override.
compose = $(CLEAN_ENV) docker compose --project-directory "$(1)"

# $(call cli_tag,VARIABLE): el valor de VARIABLE si se paso en la linea de
# comandos y no esta vacio; si no, nada.
cli_tag = $(if $(findstring command line,$(origin $(1))),$(strip $($(1))))
# $(call release_env,VARIABLE): " VARIABLE="valor"" para env, o nada.
release_env = $(if $(call cli_tag,$(1)), $(1)="$(call cli_tag,$(1))")
# $(call svc_compose,DIR,VARIABLE_TAG): docker compose de extract o documents
# segun el modo. Con RELEASE=1, solo docker-compose.yml (ruta absoluta: un -f
# relativo se resuelve contra el cwd, no contra --project-directory) y el tag.
svc_compose = $(if $(RELEASE),$(CLEAN_ENV)$(call release_env,$(2)) docker compose \
	--project-directory "$(1)" -f "$(1)/docker-compose.yml",$(call compose,$(1)))
# $(call svc_up_flags,SERVICIO): flags de "up" de EXTRACT o DOCUMENTS.
svc_up_flags = $(if $(RELEASE),$(RELEASE_UP_FLAGS),$($(1)_UP_FLAGS))
# $(call show_image,DIR,VARIABLE_TAG,SERVICIO): con RELEASE=1, la imagen que
# va a correr SERVICIO, con un aviso (no falla) si es latest. Solo lee la
# imagen de "config": nunca muestra el resto, que tiene el token.
show_image = img=$$($(call svc_compose,$(1),$(2)) config --format json \
		| jq -r '.services["$(3)"].image'); \
	echo "    imagen: $$img"; \
	if [[ $$img == *:latest ]]; then \
		echo "[release] AVISO: $(3) usa latest: esta corrida no es reproducible (latest se mueve" >&2; \
		echo "[release]        con cada merge a main y --pull=missing no lo refresca). Fijarla con" >&2; \
		echo "[release]        $(2)=sha-xxxxxxx; refrescar latest: make pull RELEASE=1" >&2; \
	fi

ifneq ($(filter-out 1,$(RELEASE)),)
$(error RELEASE tiene que ser 1 o vacio, no "$(RELEASE)")
endif
ifeq ($(RELEASE),)
ifneq ($(call cli_tag,EXTRACT_IMAGE_TAG)$(call cli_tag,DOCUMENTS_IMAGE_TAG),)
$(warning EXTRACT_IMAGE_TAG y DOCUMENTS_IMAGE_TAG solo cuentan con RELEASE=1; en desarrollo se compila)
endif
endif
MODE = $(if $(RELEASE),release: imagenes de GHCR sin build,desarrollo: build local con docker-compose.override.yml)
# $(call require_dir,DIR,VARIABLE)
require_dir = test -d "$(1)" || { echo "no existe $(1): revisar $(2)" >&2; exit 1; }

.PHONY: help check network up pull wait-routes images down ps logs smoke

help: ## Muestra esta ayuda (target por defecto)
	@echo "Uso: make <target> [VARIABLE=valor ...]"
	@echo
	@echo "Targets:"
	@grep -E '^[a-z-]+:.*## ' "$(MAKEFILE_PATH)" | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'
	@echo
	@echo "Variables (valor actual):"
	@printf '  %-19s %s\n' \
		EXTRACT_DIR "$(EXTRACT_DIR)" \
		DOCUMENTS_DIR "$(DOCUMENTS_DIR)" \
		SHARED_NETWORK "$(SHARED_NETWORK)" \
		ROUTES_TIMEOUT "$(ROUTES_TIMEOUT)" \
		TRAEFIK_URL "$(TRAEFIK_URL)" \
		TRAEFIK_API "$(TRAEFIK_API)" \
		INFRA_UP_FLAGS "$(INFRA_UP_FLAGS)" \
		EXTRACT_UP_FLAGS "$(EXTRACT_UP_FLAGS)" \
		DOCUMENTS_UP_FLAGS "$(DOCUMENTS_UP_FLAGS)" \
		RELEASE "$(or $(RELEASE),vacio) ($(MODE))" \
		RELEASE_UP_FLAGS "$(RELEASE_UP_FLAGS)" \
		EXTRACT_IMAGE_TAG "$(or $(call cli_tag,EXTRACT_IMAGE_TAG),(el del .env de extract, o latest))" \
		DOCUMENTS_IMAGE_TAG "$(or $(call cli_tag,DOCUMENTS_IMAGE_TAG),(el del .env de documents, o latest))" \
		S "$(S)" \
		TAIL "$(TAIL)" \
		SMOKE_PDF "$(SMOKE_PDF)"

check: ## Precondiciones: carpetas, .env con tokens y Docker (nunca muestra tokens)
	@echo "==> check: precondiciones"
	@"$(INFRA_DIR)/scripts/check.sh" "$(INFRA_DIR)" "$(EXTRACT)" "$(DOCUMENTS)"

network: ## Crea la red compartida (SHARED_NETWORK) si no existe
	@if docker network inspect "$(SHARED_NETWORK)" >/dev/null 2>&1; then \
		echo "==> network: $(SHARED_NETWORK) ya existe"; \
	else \
		echo "==> network: creando $(SHARED_NETWORK)"; \
		docker network create "$(SHARED_NETWORK)" >/dev/null; \
	fi

up: check network ## check, red, infra, extract y documents, y espera las rutas de Traefik (RELEASE=1: imagenes de GHCR)
	@echo "==> modo $(MODE)"
	@echo "==> infra: consul, consul-acl-init y traefik ($(INFRA_DIR))"
	@$(call compose,$(INFRA_DIR)) up $(INFRA_UP_FLAGS)
	@echo "==> extract-service ($(EXTRACT))"
	$(if $(RELEASE),@$(call show_image,$(EXTRACT),EXTRACT_IMAGE_TAG,extract))
	@$(call svc_compose,$(EXTRACT),EXTRACT_IMAGE_TAG) up $(call svc_up_flags,EXTRACT)
	@echo "==> documents-service ($(DOCUMENTS))"
	$(if $(RELEASE),@$(call show_image,$(DOCUMENTS),DOCUMENTS_IMAGE_TAG,documents))
	@$(call svc_compose,$(DOCUMENTS),DOCUMENTS_IMAGE_TAG) up $(call svc_up_flags,DOCUMENTS)
	@$(MAKE) -f "$(MAKEFILE_PATH)" wait-routes
	$(if $(RELEASE),@$(MAKE) -f "$(MAKEFILE_PATH)" images)

pull: ## Con RELEASE=1, baja de GHCR las imagenes de extract y documents sin levantar (refresca latest)
	@if [[ -z "$(RELEASE)" ]]; then \
		echo "make pull baja las imagenes de GHCR del modo release: correrlo con RELEASE=1" >&2; \
		echo "(en desarrollo las imagenes se compilan con make up)" >&2; \
		exit 2; \
	fi
	@$(call require_dir,$(EXTRACT),EXTRACT_DIR)
	@$(call require_dir,$(DOCUMENTS),DOCUMENTS_DIR)
	@echo "==> pull: extract-service ($(EXTRACT))"
	@$(call show_image,$(EXTRACT),EXTRACT_IMAGE_TAG,extract)
	@$(call svc_compose,$(EXTRACT),EXTRACT_IMAGE_TAG) pull extract
	@echo "==> pull: documents-service ($(DOCUMENTS))"
	@$(call show_image,$(DOCUMENTS),DOCUMENTS_IMAGE_TAG,documents)
	@$(call svc_compose,$(DOCUMENTS),DOCUMENTS_IMAGE_TAG) pull documents

wait-routes: ## Espera (ROUTES_TIMEOUT s) a que Traefik rutee extract y documents
	@echo "==> wait-routes: esperando extract y documents en Traefik (hasta $(ROUTES_TIMEOUT) s)"
	@TRAEFIK_API="$(TRAEFIK_API)" ROUTES_TIMEOUT="$(ROUTES_TIMEOUT)" \
		EXTRACT_DIR="$(EXTRACT)" DOCUMENTS_DIR="$(DOCUMENTS)" \
		"$(INFRA_DIR)/scripts/wait-routes.sh"

images: ## Imagen, digest y revision de extract y documents corriendo (una linea por imagen)
	@echo "==> images: lo que corre extract y documents"
	@$(call require_dir,$(EXTRACT),EXTRACT_DIR)
	@$(call require_dir,$(DOCUMENTS),DOCUMENTS_DIR)
	@$(CLEAN_ENV) "$(INFRA_DIR)/scripts/images.sh" extract "$(EXTRACT)" documents "$(DOCUMENTS)"

down: ## Baja documents, extract e infra, en ese orden (sin -v: conserva volumenes y red)
	@echo "==> documents-service: down"
	@$(call require_dir,$(DOCUMENTS),DOCUMENTS_DIR)
	@$(call compose,$(DOCUMENTS)) down
	@echo "==> extract-service: down"
	@$(call require_dir,$(EXTRACT),EXTRACT_DIR)
	@$(call compose,$(EXTRACT)) down
	@echo "==> infra: down"
	@$(call compose,$(INFRA_DIR)) down

ps: ## Estado de los tres stacks
	@echo "== infra ($(INFRA_DIR))"
	@$(call compose,$(INFRA_DIR)) ps -a
	@echo
	@echo "== extract-service ($(EXTRACT))"
	@$(call require_dir,$(EXTRACT),EXTRACT_DIR)
	@$(call compose,$(EXTRACT)) ps -a
	@echo
	@echo "== documents-service ($(DOCUMENTS))"
	@$(call require_dir,$(DOCUMENTS),DOCUMENTS_DIR)
	@$(call compose,$(DOCUMENTS)) ps -a

logs: ## Sigue los logs de un stack: S=infra|extract|documents (default documents)
	@case "$(S)" in \
		infra) dir="$(INFRA_DIR)" ;; \
		extract) dir="$(EXTRACT)" ;; \
		documents) dir="$(DOCUMENTS)" ;; \
		*) echo "S tiene que ser infra, extract o documents (S=$(S))" >&2; exit 2 ;; \
	esac; \
	echo "==> logs -f de $(S) (Ctrl+C para salir)"; \
	$(call compose,$$dir) logs -f --tail="$(TAIL)"

smoke: wait-routes ## POST /extract y POST /documents por Traefik con un PDF de prueba, y smoke-traefik.sh
	@echo "==> smoke: POST /extract y POST /documents por Traefik"
	@TRAEFIK_URL="$(TRAEFIK_URL)" "$(INFRA_DIR)/scripts/smoke-documents.sh" "$(SMOKE_PDF)"
	@echo "==> smoke: scripts/smoke-traefik.sh"
	@$(CLEAN_ENV) "$(INFRA_DIR)/scripts/smoke-traefik.sh"
