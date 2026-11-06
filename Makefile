# Levanta el sistema completo en orden: red compartida -> infra (Consul,
# consul-acl-init y Traefik) -> extract-service -> documents-service, y espera
# a que Traefik rutee los dos servicios (issue #6, 12-Factor X).
# "make" solo muestra la ayuda. Ver README, "Levantar el sistema completo".
#
# Cada stack se maneja con "docker compose --project-directory <repo>": usa el
# .env de su propio repo y el nombre de proyecto de siempre (el nombre de la
# carpeta), asi que "make down" baja lo que se levanto a mano y viceversa.

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
# Flags de "docker compose up" de cada stack. Cuando las imagenes vengan de un
# registry (documents-service #34), cambiar --build por --pull=missing.
INFRA_UP_FLAGS ?= -d --wait
EXTRACT_UP_FLAGS ?= -d --build --wait
DOCUMENTS_UP_FLAGS ?= -d --build --wait
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
COMPOSE_UNSET := CONSUL_HTTP_TOKEN CONSUL_AGENT_TOKEN CONSUL_TRAEFIK_TOKEN \
	CONSUL_EXTRACT_TOKEN CONSUL_DOCUMENTS_TOKEN CONSUL_HTTP_ADDR CONSUL_ENABLED \
	COMPOSE_PROJECT_NAME COMPOSE_FILE
CLEAN_ENV = env $(addprefix -u ,$(COMPOSE_UNSET)) SHARED_NETWORK="$(SHARED_NETWORK)"
# $(call compose,DIR): docker compose del repo en DIR.
compose = $(CLEAN_ENV) docker compose --project-directory "$(1)"
# $(call require_dir,DIR,VARIABLE)
require_dir = test -d "$(1)" || { echo "no existe $(1): revisar $(2)" >&2; exit 1; }

.PHONY: help check network up wait-routes down ps logs smoke

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

up: check network ## check, red, infra, extract y documents, y espera las rutas de Traefik
	@echo "==> infra: consul, consul-acl-init y traefik ($(INFRA_DIR))"
	@$(call compose,$(INFRA_DIR)) up $(INFRA_UP_FLAGS)
	@echo "==> extract-service ($(EXTRACT))"
	@$(call compose,$(EXTRACT)) up $(EXTRACT_UP_FLAGS)
	@echo "==> documents-service ($(DOCUMENTS))"
	@$(call compose,$(DOCUMENTS)) up $(DOCUMENTS_UP_FLAGS)
	@$(MAKE) -f "$(MAKEFILE_PATH)" wait-routes

wait-routes: ## Espera (ROUTES_TIMEOUT s) a que Traefik rutee extract y documents
	@echo "==> wait-routes: esperando extract y documents en Traefik (hasta $(ROUTES_TIMEOUT) s)"
	@TRAEFIK_API="$(TRAEFIK_API)" ROUTES_TIMEOUT="$(ROUTES_TIMEOUT)" \
		EXTRACT_DIR="$(EXTRACT)" DOCUMENTS_DIR="$(DOCUMENTS)" \
		"$(INFRA_DIR)/scripts/wait-routes.sh"

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

smoke: wait-routes ## POST /documents por Traefik con un PDF de prueba y scripts/smoke-traefik.sh
	@echo "==> smoke: POST /documents por Traefik"
	@TRAEFIK_URL="$(TRAEFIK_URL)" "$(INFRA_DIR)/scripts/smoke-documents.sh" "$(SMOKE_PDF)"
	@echo "==> smoke: scripts/smoke-traefik.sh"
	@$(CLEAN_ENV) "$(INFRA_DIR)/scripts/smoke-traefik.sh"
