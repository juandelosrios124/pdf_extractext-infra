# pdf_extractext-infra

[![CI](https://github.com/juandelosrios124/pdf_extractext-infra/actions/workflows/ci.yml/badge.svg)](https://github.com/juandelosrios124/pdf_extractext-infra/actions/workflows/ci.yml)

Infraestructura compartida de los microservicios de pdf_extractext:
la red Docker `mired`, Consul (service discovery y health checks) y Traefik
(gateway del sistema).

- [extract-service](https://github.com/juandelosrios124/extract-service)
- [documents-service](https://github.com/OlivettiSantino/documents-service)

## Levantar la infraestructura

```bash
# 1. Red compartida (una sola vez por máquina; la usan los tres repos)
docker network create mired

# 2. Variables: completar CONSUL_HTTP_TOKEN con un UUID (uuidgen)
cp .env.example .env

# 3. Consul + Traefik (Traefik arranca recién cuando Consul está healthy)
docker compose up -d --wait
docker compose ps        # consul y traefik deben quedar (healthy)
```

## Consul

Servidor único con UI y ACL (`default_policy: allow`), basado en el
[ejemplo de la cátedra](https://github.com/frsrpprats/microservicios/tree/main/consul).
Imagen fija `hashicorp/consul:2.0.4`.

- **UI y API desde el host:** <http://127.0.0.1:8500/ui> (publicada solo en 127.0.0.1).
- **Desde contenedores en `mired`:** `http://consul:8500`.
- **Token de ACL:** se toma de `CONSUL_HTTP_TOKEN` (`.env`, no versionado) y se
  inyecta como `initial_management`; no está en `consul/consul.json`. Con
  `default_policy: allow` registrar y consultar servicios no lo requiere; sí las
  operaciones de administración de ACL (header `X-Consul-Token`).

Comprobación rápida:

```bash
curl http://127.0.0.1:8500/v1/status/leader      # "IP:8300"
curl http://127.0.0.1:8500/v1/catalog/services   # {"consul":[]}
docker run --rm --network mired busybox wget -qO- http://consul:8500/v1/status/leader
```

## Traefik

Gateway único del sistema (imagen fija `traefik:v3.7.17`). Todo el tráfico
hacia extract y documents entra por Traefik.

**Cómo se relaciona con Consul.** Traefik usa el provider
[Consul Catalog](https://doc.traefik.io/traefik/reference/install-configuration/providers/hashicorp/consul-catalog/):
lee el catálogo de Consul y arma routers, services y middlewares a partir de
los **tags** con que cada servicio se registra. No hay provider Docker ni se
monta `docker.sock`: los labels de Docker no se usan.

- `exposedByDefault=false`: solo se publican los servicios con el tag `traefik.enable=true`.
- `strictChecks=passing`: solo reciben tráfico las instancias con todos sus checks
  en `passing` (el default de Traefik también admite `warning`). Si una réplica
  pasa a `critical`, Traefik la saca del balanceo.
- `watch=true`: Traefik se entera de los cambios del catálogo al instante, sin
  esperar el polling de 15 s.
- Se conecta a `consul:8500` con el token `CONSUL_HTTP_TOKEN`.

Los circuit breakers, retries y demás middlewares **no** se configuran acá: los
declara cada servicio en sus tags. Lo que no se puede expresar con tags (por
ejemplo un `serversTransport` con timeouts) va en
[`traefik/dynamic.yml`](traefik/dynamic.yml) (provider `file`, se recarga en caliente):

| Nombre | Uso | Valor actual |
|---|---|---|
| `extract-transport@file` | `responseHeaderTimeout` hacia las réplicas de extract | `60s` (el definitivo sale de #5) |

La configuración estática está en los flags de `command:` del compose y no en un
`traefik.yml`: Traefik toma la configuración estática de **una sola** fuente
(archivo, CLI o variables de entorno, mutuamente excluyentes), y por CLI Compose
puede interpolar el token desde `.env`.

### Puertos

| Host | Entrypoint | Para qué |
|---|---|---|
| `127.0.0.1:8080` (`TRAEFIK_PORT`) | `web` (`:80`) | Tráfico hacia los servicios. |
| `127.0.0.1:8081` (`TRAEFIK_DASHBOARD_PORT`) | `traefik` (`:8080`) | Dashboard (`/dashboard/`), API (`/api/...`), `/ping` y `/metrics` (Prometheus). |

Ambos se publican solo en `127.0.0.1`. El dashboard se sirve en modo
`api.insecure` (sin autenticación) justamente porque ese puerto no sale de la máquina.

### Publicar un servicio en Traefik

Basta con agregar tags al registro en Consul. Ejemplo con la API del agente:

```json
{
  "ID": "extract-1",
  "Name": "extract",
  "Address": "extract-1",
  "Port": 8000,
  "Tags": [
    "traefik.enable=true",
    "traefik.http.routers.extract.rule=PathPrefix(`/extract`)",
    "traefik.http.routers.extract.entrypoints=web",
    "traefik.http.services.extract.loadbalancer.serverstransport=extract-transport@file"
  ],
  "Check": { "HTTP": "http://extract-1:8000/health", "Interval": "5s" }
}
```

`Address` tiene que ser resolvible desde la red `mired` (nombre del contenedor).
Todas las réplicas registradas con el mismo `Name` quedan en el mismo service de
Traefik, que balancea entre las que están `passing`.

### Verificar

```bash
curl -s 127.0.0.1:8081/ping                  # OK
curl -s 127.0.0.1:8081/api/overview          # providers: ConsulCatalog y File
curl -i 127.0.0.1:8080/extract               # 404 mientras no haya servicios registrados
curl -s 127.0.0.1:8081/metrics | head        # métricas traefik_*
scripts/smoke-traefik.sh                     # whoami de prueba registrado en Consul y ruteado por Traefik
```

`scripts/smoke-traefik.sh` levanta un `traefik/whoami` en `mired`, lo registra en
Consul con tags de Traefik y un check HTTP, espera a que esté `passing` y
comprueba que `127.0.0.1:8080/whoami` responda `200`. Al terminar (bien o mal)
lo desregistra y borra el contenedor. Toma `CONSUL_HTTP_TOKEN` del entorno o,
si no está, del `.env` (otro archivo con `ENV_FILE=...`).

Logs de acceso (JSON, uno por pedido, con `X-Request-ID`):

```bash
docker compose logs -f traefik
```

## CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) corre en cada push a `main` y
en cada pull request. Los jobs que necesitan `.env` lo generan desde `.env.example`
con un token de prueba (`uuidgen`); el `.env` real nunca se usa.

- **`lint`**: `actionlint` sobre el workflow, `shellcheck` sobre `scripts/*.sh`, y que
  `traefik/dynamic.yml` (`yamllint -d relaxed`) y `consul/consul.json` (`jq`) parseen.
- **`compose`**: `docker compose config --quiet` resuelve sin errores y `.env` no está versionado.
- **`consul-config`**: `consul validate` de `consul/consul.json` con la misma imagen
  del compose (la toma de `docker compose config`).
- **`smoke`** (después de `lint` y `compose`): `docker compose up -d --wait`, Consul con
  líder, Traefik responde `/ping` con los providers ConsulCatalog y File, y
  `scripts/smoke-traefik.sh` pasa. Si falla, muestra `docker compose logs`; siempre
  termina con `docker compose down -v`.

Las imágenes de Consul y Traefik están fijadas por tag **y digest** en el compose.
Para actualizar una versión, cambiar el tag y obtener el digest nuevo con
`docker buildx imagetools inspect <imagen>:<tag>` (campo `Digest`).

## Variables compartidas

Los tres repos usan **estos mismos nombres**. Si se cambia alguno, cambiarlo en todos.

| Variable | Default | La usan | Descripción |
|---|---|---|---|
| `SHARED_NETWORK` | `mired` | infra, extract, documents | Nombre de la red Docker externa compartida. |
| `CONSUL_HTTP_TOKEN` | *(obligatoria, sin default)* | infra, extract, documents | Token de ACL de Consul (UUID, `uuidgen`). Mismo valor en los tres `.env`; nunca en el repo. También lo usa Traefik para leer el catálogo. |
| `CONSUL_HTTP_ADDR` | `http://consul:8500` | extract, documents | URL de Consul desde la red `mired`. |
| `CONSUL_ENABLED` | `false` | extract, documents | Activa el registro/discovery. Sin Consul los servicios funcionan igual. |
| `CONSUL_UI_PORT` | `8500` | infra | Puerto del host para la UI/API, siempre en `127.0.0.1`. |
| `TRAEFIK_PORT` | `8080` | infra | Puerto del host para el tráfico (entrypoint `web`), siempre en `127.0.0.1`. |
| `TRAEFIK_DASHBOARD_PORT` | `8081` | infra | Puerto del host para dashboard, API, ping y métricas, siempre en `127.0.0.1`. |
| `TRAEFIK_CPUS` | `0.5` | infra | Límite de CPU del contenedor de Traefik. |
| `TRAEFIK_MEMORY` | `256M` | infra | Límite de memoria del contenedor de Traefik. |

`CONSUL_HTTP_ADDR` y `CONSUL_HTTP_TOKEN` son los nombres estándar que reconoce la CLI de `consul`.

## Apagar

```bash
docker compose down      # conserva los datos (volumen consul_data)
```

`docker compose down -v` borra también el volumen (catálogo y estado de ACL).
La red `mired` no la borra este compose, porque es externa.
