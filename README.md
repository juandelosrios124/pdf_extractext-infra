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
| `extract-transport@file` | Timeouts hacia las réplicas de extract | `dialTimeout: 2s`, `responseHeaderTimeout: 25s` (ver [Presupuesto de timeouts](#presupuesto-de-timeouts)) |

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
scripts/smoke-timeouts.sh                    # presupuesto de timeouts (200 a 20 s, 504 a 25 s); ~1,5 min
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

## Presupuesto de timeouts

**Esta tabla es la fuente de verdad de los timeouts de punta a punta.** Cualquier
cambio de un timeout, en cualquiera de los tres repos, se hace primero acá y
después en el código o la configuración. extract-service y documents-service
enlazan esta sección.

**Regla: cada capa corta antes que la capa que la llama.** Si una capa interna
tardara más que la que la llama, seguiría gastando CPU en una respuesta que
nadie va a leer, porque la capa de afuera ya se rindió:

```
cliente 30 s  >  documents 27 s  >  Traefik 25 s  ≥  extract 23 s
```

| Capa | Parámetro | Valor | Dónde | Issue |
|---|---|---|---|---|
| Cliente (k6/Vegeta) | timeout | 30 s | scripts de carga | — |
| documents → Traefik | `EXTRACT_TIMEOUT` / `EXTRACT_CONNECT_TIMEOUT` | 27 s / 2 s | documents-service | "Eliminar circuit breaker, bulkhead, retry y discovery propios" |
| Traefik, entrypoint `web` | `readTimeout` / `writeTimeout` / `idleTimeout` | 30 s / **60 s** / 90 s | este repo: flags del compose (`TRAEFIK_READ_TIMEOUT`, `TRAEFIK_WRITE_TIMEOUT`, `TRAEFIK_IDLE_TIMEOUT`) | #5 |
| Traefik → réplica de extract | `dialTimeout` / `responseHeaderTimeout` | 2 s / 25 s | este repo: `extract-transport` en [`traefik/dynamic.yml`](traefik/dynamic.yml) | #5 |
| extract | `UPLOAD_SLOT_TIMEOUT` + `MAX_QUEUE_WAIT` + `EXTRACTION_DEADLINE` | 5 s + hasta 15 s + 8 s = 23 s | extract-service | "Deadline y límite de páginas en la extracción" |

### Qué mide cada timeout de Traefik

Son los de `net/http` de Go:

- **`readTimeout`** (entrypoint): lectura del request **completo**, headers y body,
  desde que llega la conexión. Limita la subida del PDF.
- **`writeTimeout`** (entrypoint): desde que se terminaron de leer los headers del
  request hasta que se termina de escribir la respuesta. Por eso **incluye la subida
  del body y la espera a extract**. No es un corte del presupuesto: es una red de
  seguridad contra clientes que no leen la respuesta.
- **`idleTimeout`** (entrypoint): cuánto puede quedar ociosa una conexión
  keep-alive del cliente entre pedidos.
- **`dialTimeout`** (`serversTransport`): cuánto se espera para conectar por TCP con
  la réplica.
- **`responseHeaderTimeout`** (`serversTransport`): cuánto se esperan los headers de
  respuesta de la réplica, **contado desde que Traefik terminó de enviarle el request
  con su body**. Es el corte efectivo de Traefik dentro del presupuesto.

**Por qué `writeTimeout` es 60 s y no 30 s.** El 504 de `responseHeaderTimeout` sale
a los *subida + 25 s* contados desde los headers del request, y `writeTimeout`
cuenta desde ese mismo momento. Con `writeTimeout: 30s`, cualquier subida de más de
5 s haría que Traefik cerrara la conexión **sin enviar el 504**: el cliente vería
`Empty reply from server`, sin código, y no se distinguiría de una caída. La subida
está acotada por `readTimeout` (30 s), así que el mínimo que nunca corta el 504 es
`readTimeout + responseHeaderTimeout = 30 + 25 = 55 s`. Se usan **60 s** para dejar
margen a la escritura del body de una respuesta `200`. El caso 3 de
`scripts/smoke-timeouts.sh` lo comprueba con una subida lenta. Con 60 s no se rompe
la regla: ningún pedido que el cliente siga esperando dura más de 30 s, porque lo
cortan `readTimeout` o `responseHeaderTimeout` antes.

### Qué pasa cuando se supera cada uno

| Timeout superado | Quién corta | Qué recibe quien llamó |
|---|---|---|
| Cliente, 30 s | k6/Vegeta | Error de timeout del cliente; no hay código HTTP. No debería pasar si las capas de adentro respetan el presupuesto. |
| `EXTRACT_TIMEOUT`, 27 s / `EXTRACT_CONNECT_TIMEOUT`, 2 s | documents | Lo que documents devuelva al cliente ante un timeout de extract (lo define su issue). |
| `readTimeout`, 30 s (subida demasiado lenta) | Traefik | Conexión cerrada. Traefik registra `499` en el access log y no llama a extract. |
| `writeTimeout`, 60 s | Traefik | Conexión cerrada sin respuesta (`Empty reply from server`). |
| `idleTimeout`, 90 s | Traefik | Cierra la conexión keep-alive ociosa. No afecta pedidos en curso. |
| `dialTimeout`, 2 s (réplica que no acepta conexiones) | Traefik | `504 Gateway Timeout` a los 2 s. |
| `responseHeaderTimeout`, 25 s (extract no respondió a tiempo) | Traefik | `504 Gateway Timeout` a los 25 s, contados desde que terminó la subida. |
| Presupuesto de extract, 23 s | extract | La respuesta de error de extract (la define su issue), que Traefik reenvía tal cual. |

Valores medidos con Traefik v3.7.17: `readTimeout` → 499 a los 30 s; `dialTimeout` contra
una IP que no responde → 504 a los 2,0 s; `responseHeaderTimeout` → 504 a los 25,0 s.

### Comprobar

```bash
scripts/smoke-timeouts.sh
```

Registra un `traefik/whoami` en Consul con `extract-transport@file`, el mismo transport
que usa extract, y usa `?wait=` para demorar la respuesta:

1. `wait=20s` → `200`.
2. `wait=28s` → `504` a los ~25 s.
3. `wait=40s` con una subida de ~8 s → `504` a los ~33 s, sin que lo corte `writeTimeout`.

Antes de los casos comprueba en la API de Traefik que el service use ese transport. Al
salir siempre desregistra el servicio y borra el contenedor.

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
  líder, Traefik responde `/ping` con los providers ConsulCatalog y File, y pasan
  `scripts/smoke-traefik.sh` y `scripts/smoke-timeouts.sh`. Si falla, muestra `docker compose logs`; siempre
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
| `TRAEFIK_READ_TIMEOUT` | `30s` | infra | `readTimeout` del entrypoint `web`. Ver [Presupuesto de timeouts](#presupuesto-de-timeouts). |
| `TRAEFIK_WRITE_TIMEOUT` | `60s` | infra | `writeTimeout` del entrypoint `web`. Con menos de 55 s puede cortar el 504 de Traefik. |
| `TRAEFIK_IDLE_TIMEOUT` | `90s` | infra | `idleTimeout` del entrypoint `web` (keep-alive ocioso). |
| `TRAEFIK_CPUS` | `0.5` | infra | Límite de CPU del contenedor de Traefik. |
| `TRAEFIK_MEMORY` | `256M` | infra | Límite de memoria del contenedor de Traefik. |

`CONSUL_HTTP_ADDR` y `CONSUL_HTTP_TOKEN` son los nombres estándar que reconoce la CLI de `consul`.

## Apagar

```bash
docker compose down      # conserva los datos (volumen consul_data)
```

`docker compose down -v` borra también el volumen (catálogo y estado de ACL).
La red `mired` no la borra este compose, porque es externa.
