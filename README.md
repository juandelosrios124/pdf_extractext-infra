# pdf_extractext-infra

[![CI](https://github.com/juandelosrios124/pdf_extractext-infra/actions/workflows/ci.yml/badge.svg)](https://github.com/juandelosrios124/pdf_extractext-infra/actions/workflows/ci.yml)

Infraestructura compartida de los microservicios de pdf_extractext:
la red Docker `mired`, Consul (service discovery y health checks) y Traefik
(gateway del sistema).

- [extract-service](https://github.com/juandelosrios124/extract-service)
- [documents-service](https://github.com/OlivettiSantino/documents-service)

## Levantar el sistema completo

**Camino recomendado para desarrollar y probar.** El [`Makefile`](Makefile) levanta
los tres repos en orden y por el mismo camino que el sistema real: Consul con ACL,
Traefik y los servicios registrados con su token.

Requisitos: los tres repos clonados en la misma carpeta padre (`pdf_extractext-infra`,
`extract-service`, `documents-service`), cada uno con su `.env` (ver
[Qué va en el `.env` de cada repo](#qué-va-en-el-env-de-cada-repo)), Docker con Compose
v2, GNU Make, `curl` y `jq`.

```bash
make up      # check → red → infra → extract → documents → espera las rutas de Traefik
make up RELEASE=1 EXTRACT_IMAGE_TAG=sha-xxxxxxx DOCUMENTS_IMAGE_TAG=sha-yyyyyyy  # imágenes de GHCR, sin compilar
make smoke   # POST /extract y POST /documents por Traefik (201 o 200 duplicate), y smoke-traefik.sh
make ps      # estado de los tres stacks
make down    # documents → extract → infra; conserva volúmenes y red
```

Funciona igual desde fish o cualquier otro shell: el Makefile fija `SHELL := bash`.
`make` sin target muestra la ayuda.

| Target | Qué hace |
|---|---|
| `help` | Lista los targets y las variables con su valor actual. Es el default. |
| `check` | Precondiciones: existen las carpetas de los repos y su `.env`, los tokens no están vacíos, el `CONSUL_HTTP_TOKEN` de extract y de documents es el `CONSUL_EXTRACT_TOKEN` y el `CONSUL_DOCUMENTS_TOKEN` de infra, `CONSUL_ENABLED` no está apagado, el `EXTRACT_URL` de documents no apunta a `localhost`, y Docker responde. Junta todos los errores y cada uno dice qué hacer. **Nunca muestra tokens.** ([`scripts/check.sh`](scripts/check.sh)) |
| `network` | Crea la red `SHARED_NETWORK` si no existe. Si ya está, no hace nada. |
| `up` | `check` → `network` → infra `up -d --wait` → extract `up -d --build --wait` → documents `up -d --build --wait` → `wait-routes`. Con `RELEASE=1`, extract y documents van con `-f <repo>/docker-compose.yml up -d --pull=missing --wait` y al final corre `images` (ver [Modo release](#modo-release-imágenes-de-ghcr)). |
| `pull` | Solo con `RELEASE=1`: baja de GHCR las imágenes de extract y documents sin levantar nada. Sirve para refrescar `latest`. |
| `wait-routes` | Espera hasta `ROUTES_TIMEOUT` s a que la API de Traefik muestre los routers `extract@consulcatalog` y `documents@consulcatalog` con servidores. ([`scripts/wait-routes.sh`](scripts/wait-routes.sh)) |
| `images` | Para extract y documents corriendo: imagen configurada, digest del registry (`RepoDigests`) y label `org.opencontainers.image.revision`, una línea por imagen distinta (no por réplica). En desarrollo dice `build local, sin digest`. ([`scripts/images.sh`](scripts/images.sh)) |
| `down` | `docker compose down` en documents, extract e infra, en ese orden. **Sin `-v`** (conserva `consul_data` y la base de Mongo) y sin borrar la red. |
| `ps` | `docker compose ps -a` de los tres stacks, con un título por stack. |
| `logs` | `logs -f` de un stack: `make logs S=infra`, `S=extract` o `S=documents` (default). `TAIL` líneas previas. |
| `smoke` | `wait-routes`; con un PDF de prueba de extract, `POST /extract` por Traefik (`200`, no guarda nada) y `POST /documents` por Traefik (`201`, o `200` con `"duplicate": true` si ya estaba) ([`scripts/smoke-documents.sh`](scripts/smoke-documents.sh)); y [`scripts/smoke-traefik.sh`](scripts/smoke-traefik.sh). El `POST /extract` hace falta porque un duplicado no llama a extract. |

**Por qué `wait-routes`.** `docker compose up --wait` espera el healthcheck de Docker,
no el check de Consul: una réplica entra en la rotación de Traefik unos segundos
después, cuando su check pasa a `passing` (hasta un intervalo, 10 s). Sin esa espera,
un `POST /documents` justo después del `up` puede recibir `404` de Traefik. Si vence
`ROUTES_TIMEOUT`, la causa más probable es un `CONSUL_HTTP_TOKEN` vacío o equivocado:
el contenedor arranca `healthy`, pero Consul rechaza su registro con `403` y Traefik
nunca lo rutea. El mensaje de error dice cómo buscar el `403` en los logs.

**`make up` es repetible.** Sobre un sistema ya levantado no recrea contenedores si
nada cambió: el build sale de la caché, `consul-acl-init` vuelve a correr (es
idempotente) y `wait-routes` pasa enseguida. Si cambió el `.env` o el código de un
servicio, `make up` recrea solo esos contenedores.

### Variables

Se pasan en la línea de comandos (`make up EXTRACT_DIR=/otra/ruta`).

| Variable | Default | Para qué |
|---|---|---|
| `EXTRACT_DIR` | `../extract-service` | Carpeta de extract-service, relativa a este repo o absoluta. |
| `DOCUMENTS_DIR` | `../documents-service` | Carpeta de documents-service, relativa a este repo o absoluta. |
| `SHARED_NETWORK` | `mired` | Red que crea `network`. Se pasa a los tres compose, así la red creada es la que usan. |
| `ROUTES_TIMEOUT` | `60` | Segundos que espera `wait-routes`. |
| `TRAEFIK_URL` | `http://127.0.0.1:8080` | Tráfico de Traefik (`TRAEFIK_PORT`), para `smoke`. |
| `TRAEFIK_API` | `http://127.0.0.1:8081` | API de Traefik (`TRAEFIK_DASHBOARD_PORT`), para `wait-routes`. |
| `INFRA_UP_FLAGS` | `-d --wait` | Flags de `docker compose up` de infra. |
| `EXTRACT_UP_FLAGS` | `-d --build --wait` | Ídem extract, en modo desarrollo. Cambiar `--build` por `--pull=missing` **no** alcanza para usar GHCR: sin `-f`, Compose siempre lee el override y compila. Para eso está `RELEASE=1`. |
| `DOCUMENTS_UP_FLAGS` | `-d --build --wait` | Ídem documents, en modo desarrollo. |
| `RELEASE` | vacío | Vacío: desarrollo. `1`: [modo release](#modo-release-imágenes-de-ghcr). Otro valor es un error. |
| `RELEASE_UP_FLAGS` | `-d --pull=missing --wait` | Flags de `up` de extract y documents con `RELEASE=1` (reemplazan a `EXTRACT_UP_FLAGS` y `DOCUMENTS_UP_FLAGS`). |
| `EXTRACT_IMAGE_TAG` | el del `.env` de extract, o `latest` | Tag de `ghcr.io/juandelosrios124/extract-service` con `RELEASE=1`. Solo cuenta si se pasa en la línea de comandos con un valor. |
| `DOCUMENTS_IMAGE_TAG` | el del `.env` de documents, o `latest` | Ídem `ghcr.io/olivettisantino/documents-service`. |
| `S` | `documents` | Stack de `make logs`: `infra`, `extract` o `documents`. |
| `TAIL` | `100` | Líneas previas de `make logs`. |
| `SMOKE_PDF` | `$(EXTRACT_DIR)/tests/stress/pdfs/2020-Scrum-Guide-Spanish-Latin-South-American.pdf` | PDF que sube `make smoke`. |

### Cada stack usa el `.env` de su repo

Cada stack se maneja con `docker compose --project-directory <repo>`. Compose toma el
`.env` del directorio del proyecto, que es `--project-directory` si está
([Interpolation, `.env` file](https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/#env-file)),
y el nombre del proyecto es el nombre de esa carpeta
([Specify a project name](https://docs.docker.com/compose/how-tos/project-name/)).

Pero Compose le da **prioridad a las variables del entorno del shell sobre el `.env`**.
Un `CONSUL_HTTP_TOKEN` exportado en la terminal pisaría el token de cada repo: extract y
documents arrancarían `healthy` sin registrarse en Consul (`403`), y en infra
`consul-acl-init` fallaría. Por eso el Makefile no exporta ninguna variable y corre cada
`docker compose` (y `smoke-traefik.sh`) con `env -u` de `CONSUL_HTTP_TOKEN`,
`CONSUL_AGENT_TOKEN`, `CONSUL_TRAEFIK_TOKEN`, `CONSUL_EXTRACT_TOKEN`,
`CONSUL_DOCUMENTS_TOKEN`, `CONSUL_HTTP_ADDR`, `CONSUL_ENABLED`, `COMPOSE_PROJECT_NAME`,
`COMPOSE_FILE`, `EXTRACT_IMAGE_TAG` y `DOCUMENTS_IMAGE_TAG`. Las únicas que se pasan
explícitas son `SHARED_NETWORK` y, con `RELEASE=1`, el tag que se le haya pasado a make
(ver [Modo release](#modo-release-imágenes-de-ghcr)). Cualquier otra
variable exportada (por ejemplo `LOG_LEVEL`) sigue pisando el `.env`, igual que con
`docker compose` a mano.

### Modo release (imágenes de GHCR)

La CI de extract y de documents publica en GHCR una imagen por cada merge a `main`
(`sha-<7>` y `latest`; ver "Imagen y releases" en el README de cada repo). `RELEASE=1`
levanta esas imágenes, sin compilar:

```bash
make up RELEASE=1 EXTRACT_IMAGE_TAG=sha-ec5b762 DOCUMENTS_IMAGE_TAG=sha-3ef65f2
make smoke
make images   # lo que va en la fila "Imagen" del informe de una medición
```

`make images` muestra, por servicio:

```text
extract    5 replicas  ghcr.io/juandelosrios124/extract-service:sha-ec5b762  digest ghcr.io/juandelosrios124/extract-service@sha256:…  revision ec5b762…
documents  1 replica   ghcr.io/olivettisantino/documents-service:sha-3ef65f2  digest ghcr.io/olivettisantino/documents-service@sha256:…  revision 3ef65f2…
```

**Cuándo usar cada modo.**

- **Desarrollo** (`make up`): compila lo que tenés en la carpeta de cada repo, con tus
  cambios sin commitear. Es el de todos los días.
- **Release** (`make up RELEASE=1 …`): corre exactamente la imagen que construyó la CI
  para un commit. Es el que se usa **para medir** (pruebas de carga, comparar
  versiones): dos corridas con el mismo tag corren el mismo binario, y el digest de
  `make images` lo identifica aunque el tag se mueva.

**Qué cambia con `RELEASE=1`.** Solo extract y documents; infra es igual (no tiene build).

- Se agrega `-f <ruta absoluta del repo>/docker-compose.yml`. Sin `-f`, Compose lee
  siempre `docker-compose.override.yml`, que agrega `build: .` e `image: <repo>:dev`
  ([Merge Compose files](https://docs.docker.com/compose/how-tos/multiple-compose-files/merge/)):
  cambiar `--build` por `--pull=missing` no alcanza. La ruta es absoluta porque un `-f`
  relativo se resuelve contra el directorio desde donde se corre, no contra
  `--project-directory`.
- `RELEASE_UP_FLAGS` (`-d --pull=missing --wait`) en lugar de `--build`. `missing` y no
  `always`: un `sha-xxxxxxx` o un `vX.Y.Z` no cambia, así que bajarlo una vez alcanza.
  La contra es `latest`: si ya está en la máquina, `missing` no lo vuelve a bajar (probado
  con Compose 5.6.1). Para refrescarlo: `make pull RELEASE=1`.
- El nombre del proyecto es el mismo con y sin `-f` (el de la carpeta, por
  `--project-directory`; [Specify a project name](https://docs.docker.com/compose/how-tos/project-name/)).
  Por eso `make down`, `make ps` y `make logs` funcionan igual sobre lo que levantó
  cualquiera de los dos modos y no llevan `-f`: Compose encuentra los contenedores por el
  proyecto y el servicio, que son los mismos.

**Tags.** Se pasan como variables de make: `EXTRACT_IMAGE_TAG=sha-…` y
`DOCUMENTS_IMAGE_TAG=sha-…`. Cada uno llega solo al compose de su servicio, y solo si se
pasó en la línea de comandos con un valor. Si no, vale el `EXTRACT_IMAGE_TAG` /
`DOCUMENTS_IMAGE_TAG` del `.env` de cada repo, y si tampoco está ahí, `latest`. Con
`latest`, `make up RELEASE=1` avisa que la corrida no es reproducible, pero levanta igual.

Un tag **exportado en la terminal no cuenta**: el Makefile lo borra con `env -u`, como
los tokens. Si no, un `export EXTRACT_IMAGE_TAG=…` olvidado de otra medición cambiaría
la imagen sin aparecer en el comando. Tampoco cuenta uno vacío (`EXTRACT_IMAGE_TAG=`):
Make pasa al entorno de las recetas las variables de la línea de comandos aunque estén
vacías, y vacío pisaría el `.env` y dejaría `latest`.

**Cambiar de modo recrea los contenedores.** Cambia la imagen (`<repo>:dev` ↔
`ghcr.io/…:sha-…`), así que el `up` del otro modo recrea las réplicas de extract y
documents; Mongo y su volumen quedan como están. No hace falta `make down` antes. Volver a
desarrollo es `make up` (recompila; `make images` vuelve a decir `build local`).

### Levantar un stack a mano

Es compatible: `make` y `docker compose` a mano usan los mismos proyectos de Compose
(`pdf_extractext-infra`, `extract-service` y `documents-service`, el nombre de cada
carpeta). `make ps` y `make down` ven lo que se levantó a mano, y `docker compose down`
en un repo baja lo que levantó `make up`. Por ejemplo, para reconstruir solo extract
después de un cambio, alcanza con `docker compose up -d --build --wait` en su carpeta.
Lo único distinto: a mano, una variable exportada en el shell sí pisa el `.env`.

### `uv run`

`uv run` queda **solo para los tests unitarios** de cada servicio. Un servicio corriendo
con `uv run` no pasa por Consul ni por Traefik, así que no prueba el camino real.

## Levantar la infraestructura

Camino manual, solo infra. Para el sistema completo, ver
[Levantar el sistema completo](#levantar-el-sistema-completo).

```bash
# 1. Red compartida (una sola vez por máquina; la usan los tres repos)
docker network create mired

# 2. Variables: completar los cinco tokens de Consul con UUID distintos
#    (uuidgen; ver "ACL" más abajo)
cp .env.example .env

# 3. Consul, bootstrap de ACL y Traefik. Traefik arranca recién cuando Consul
#    está healthy y consul-acl-init terminó bien.
docker compose up -d --wait
docker compose ps -a     # consul y traefik (healthy); consul-acl-init Exited (0)
```

## Consul

Servidor único con UI y ACL (`default_policy: deny`, ver [ACL](#acl)), basado en el
[ejemplo de la cátedra](https://github.com/frsrpprats/microservicios/tree/main/consul).
Imagen fija `hashicorp/consul:2.0.4`.

- **UI y API desde el host:** <http://127.0.0.1:8500/ui> (publicada solo en 127.0.0.1).
- **Desde contenedores en `mired`:** `http://consul:8500`.
- **Tokens de ACL:** salen del `.env` (no versionado) y se inyectan por
  `CONSUL_LOCAL_CONFIG`; no están en `consul/consul.json`. Sin token no se puede
  registrar nada y las lecturas vuelven vacías. Ver [ACL](#acl).

Comprobación rápida (`/v1/status/*` no pide token):

```bash
curl http://127.0.0.1:8500/v1/status/leader      # "IP:8300"
curl http://127.0.0.1:8500/v1/catalog/services   # {}: sin token no se ve nada
docker compose exec consul consul catalog services   # con el token de management del contenedor
docker run --rm --network mired busybox wget -qO- http://consul:8500/v1/status/leader
```

## ACL

Con Traefik leyendo los tags del catálogo, **quien puede registrar en Consul
controla el ruteo**: con `default_policy: allow` cualquier contenedor de `mired`
podía registrar un `extract` falso con tags de Traefik y desviar el tráfico.
Por eso Consul corre con `default_policy: deny` y cada componente tiene su propio
token con lo mínimo que necesita.

### Tokens y policies

Las policies están versionadas en [`consul/policies/`](consul/policies/), una por
archivo (`<nombre>.hcl` → policy `<nombre>`). Los SecretID los genera cada
integrante con `uuidgen` y van solo en su `.env`.

| Variable (`.env` de infra) | Policy | Reglas | Quién lo usa | Por qué es el mínimo |
|---|---|---|---|---|
| `CONSUL_HTTP_TOKEN` | `global-management` | todo | `consul-acl-init`, la CLI dentro del contenedor de consul y los smoke tests de infra | Es el `initial_management`. **Solo infra**: no se copia a ningún otro repo. |
| `CONSUL_AGENT_TOKEN` | `agent` | `node "ds"` write, `service_prefix ""` read | el propio agente de Consul (`acl.tokens.agent`) | Lo que pide la [documentación del token de agente](https://developer.hashicorp.com/consul/docs/v2.0.x/secure/acl/token/agent): `node:write` sobre su nodo para mantenerlo en el catálogo (anti-entropy, coordenadas) y `service:read`. |
| `CONSUL_TRAEFIK_TOKEN` | `traefik` | `service_prefix ""` read, `node_prefix ""` read | Traefik (`providers.consulcatalog.endpoint.token`) | Traefik solo lee `/v1/catalog/services` y `/v1/health/service/<nombre>`. Consul filtra esas respuestas por servicio **y por nodo**: sin `node:read` las dos vuelven vacías. Sin ningún write. |
| `CONSUL_EXTRACT_TOKEN` | `extract` | `service "extract"` write | extract-service | Registrar y desregistrar sus réplicas (y sus checks). No puede registrar otro nombre. |
| `CONSUL_DOCUMENTS_TOKEN` | `documents` | `service "documents"` write | documents-service | Ídem para `documents`. No lee `extract`: a extract lo descubre Traefik. |

El token del agente va en la configuración (`CONSUL_LOCAL_CONFIG`), no con
`consul acl set-agent-token`. Con `enable_token_persistence` el token que se fija
por la API se guarda en `/consul/data/acl-tokens.json` y **le gana** al de la
configuración en cada reinicio, así que un cambio en el `.env` dejaría de tener
efecto. Si alguien lo usó, el log de Consul lo avisa con `"agent" token present
in both the configuration and persisted token store`.

`down_policy` queda explícito en `extend-cache`, que ya es el default. Solo se
aplica cuando no se puede resolver un token contra el líder. Con un servidor
único eso pasa solo mientras no hay líder (por ejemplo, durante un reinicio). En
ese caso `extend-cache` sigue aceptando los tokens que ya estaban en caché, en
lugar de rechazar todo (`deny`) o aceptar todo (`allow`). Va explícito porque
HashiCorp avisa que algunos defaults de ACL van a cambiar.

### Generar los tokens

Cinco UUID distintos en el `.env` de infra. `CONSUL_HTTP_TOKEN` ya existe si la
infra estaba levantada: **no cambiarlo**, porque es el `initial_management` del
volumen. Los otros cuatro, en fish, para pegar en el `.env`:

```fish
for v in AGENT TRAEFIK EXTRACT DOCUMENTS; echo "CONSUL_"$v"_TOKEN="(uuidgen); end
```

Después, `docker compose up -d --wait`. `consul-acl-init`
([`scripts/acl-bootstrap.sh`](scripts/acl-bootstrap.sh)) corre en cada `up` y deja
creadas o actualizadas las policies y los tokens con esos SecretID:

- es idempotente: correrlo de nuevo actualiza en vez de duplicar
  (`docker compose run --rm consul-acl-init` lo corre a mano);
- si cambia un SecretID del `.env` (rotación), crea el token nuevo y borra el
  anterior de ese servicio;
- falla si falta un token, si alguno no es un UUID o si dos se repiten;
- nunca imprime SecretIDs, solo AccessorIDs.

### Qué va en el `.env` de cada repo

| Repo | Variable | Valor |
|---|---|---|
| infra | `CONSUL_HTTP_TOKEN`, `CONSUL_AGENT_TOKEN`, `CONSUL_TRAEFIK_TOKEN`, `CONSUL_EXTRACT_TOKEN`, `CONSUL_DOCUMENTS_TOKEN` | Los cinco UUID. |
| extract-service | `CONSUL_HTTP_TOKEN` | El valor de `CONSUL_EXTRACT_TOKEN` de infra. |
| documents-service | `CONSUL_HTTP_TOKEN` | El valor de `CONSUL_DOCUMENTS_TOKEN` de infra. |

El nombre de la variable en extract y documents no cambia; cambia el valor. Después
de cambiarlo, recrear los contenedores (`docker compose up -d --wait` en cada repo).
Cada réplica se desregistra con el token viejo al apagarse y se registra con el nuevo.

### Migración desde `allow`

Una réplica registrada con `allow` y **sin token** no puede desregistrarse cuando
Consul ya está en `deny`: al apagarse recibe `403`. Su entrada queda en el
catálogo congelada en `passing` y el agente loguea `agent: Service registration
blocked by ACLs ... accessorID="anonymous token"`. Traefik puede seguir mandándole
tráfico a una IP que ya no es de esa réplica. Orden para pasar a `deny`:

1. `docker compose down` en extract-service y documents-service (todavía con
   `allow`, se desregistran bien).
2. Agregar los tokens al `.env` de infra y `docker compose up -d --wait`.
3. Poner el token de cada servicio en su `.env` y `docker compose up -d --wait` en cada repo.

Si ya quedaron entradas fantasma, desregistrarlas con el token de management. Son los
ID registrados que no son el hostname de ningún contenedor vivo:

```bash
docker compose exec consul sh -c 'curl -s -H "X-Consul-Token: $CONSUL_HTTP_TOKEN" 127.0.0.1:8500/v1/agent/services' | jq -r '.[].ID'
docker ps -q | xargs docker inspect -f '{{.Config.Hostname}}'
docker compose exec consul consul services deregister -id <ID>
```

### UI y API con token

- **UI:** <http://127.0.0.1:8500/ui> → *Log in* → pegar un token. Para administrar,
  el de management (`CONSUL_HTTP_TOKEN`). Para solo mirar servicios y nodos alcanza
  el de Traefik, que es de solo lectura. Sin login la UI no muestra nada.
- **API:** el token va en el header `X-Consul-Token`. Sin token, las lecturas
  devuelven `200` con el resultado vacío (`{}` o `[]`), no `403`. Por ejemplo, con
  el token de Traefik:

  ```bash
  # bash: cargar el .env sin imprimirlo
  set -a; . ./.env; set +a
  curl -s -H "X-Consul-Token: $CONSUL_TRAEFIK_TOKEN" "http://127.0.0.1:8500/v1/health/service/extract?passing"
  ```

  ```fish
  # fish: tomar una sola variable del .env sin imprimirla
  set -l token (string match -rg '^CONSUL_TRAEFIK_TOKEN=(.*)' < .env)
  curl -s -H "X-Consul-Token: $token" "http://127.0.0.1:8500/v1/health/service/extract?passing"
  ```

- **CLI dentro del contenedor:** `docker compose exec consul consul ...` ya tiene el
  token de management en su entorno (`consul catalog services`,
  `consul acl token list`). Ojo: `consul acl token list` muestra los SecretID.

### Comprobar

```bash
scripts/smoke-acl.sh
```

Contra el Consul levantado comprueba:

1. registrar sin token → `403`;
2. el token de extract registra y desregistra `extract`, y recibe `403` con `documents`;
3. lo mismo, al revés, con el token de documents;
4. el token de Traefik lee el catálogo y health con los datos del nodo, y recibe `403` al registrar;
5. sin token `/v1/catalog/services` devuelve `200 {}` (Consul 2.0.4 filtra, no rechaza);
6. el token del agente tiene la policy `agent`, el nodo `ds` tiene sus direcciones en el
   catálogo y, desde que terminó `consul-acl-init`, el log de Consul no tiene errores de
   ACL del agente (por ejemplo `agent: Coordinate update blocked by ACLs`, o
   `Service registration blocked by ACLs` si quedaron réplicas registradas sin token:
   ver [Migración desde `allow`](#migración-desde-allow)). `SINCE=<fecha>` cambia el
   inicio de esa ventana.

Toma los tokens del entorno o del `.env` y nunca los imprime. Los servicios de prueba
no tienen tags de Traefik, así que no reciben tráfico aunque extract y documents estén
levantados.

### Rollback

Para volver a `allow` sin tocar tokens ni servicios:

1. En [`consul/consul.json`](consul/consul.json), `"default_policy": "allow"`.
2. `docker compose up -d --force-recreate --wait consul` (recrear y no solo reiniciar:
   `consul.json` se monta como archivo, y si el editor lo reemplaza un `restart`
   puede seguir viendo el viejo).

Los tokens y policies siguen existiendo y los servicios siguen funcionando con sus
tokens. Lo que cambia es que todo lo que no está cubierto por una regla vuelve a
estar permitido, incluso sin token. No hace falta borrar el volumen.

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
- Se conecta a `consul:8500` con su propio token, `CONSUL_TRAEFIK_TOKEN`, de solo
  lectura (ver [ACL](#acl)).

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
scripts/smoke-acl.sh                         # ACL: 403 sin token o con el token de otro servicio (ver ACL)
scripts/smoke-traefik.sh                     # whoami de prueba registrado en Consul y ruteado por Traefik
scripts/smoke-timeouts.sh                    # presupuesto de timeouts (200 a 20 s, 504 a 25 s); ~1,5 min
```

`scripts/smoke-traefik.sh` levanta un `traefik/whoami` en `mired`, lo registra en
Consul con tags de Traefik y un check HTTP, espera a que esté `passing` y
comprueba que `127.0.0.1:8080/whoami` responda `200`. Al terminar (bien o mal)
lo desregistra y borra el contenedor. Toma `CONSUL_HTTP_TOKEN` del entorno o,
si no está, del `.env` (otro archivo con `ENV_FILE=...`). Registra con el token de
management porque es una prueba de la infraestructura (lo mismo
`smoke-timeouts.sh`); Traefik lo ve con su propio token.

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
con un `uuidgen` nuevo para cada uno de los cinco tokens; el `.env` real nunca se usa.

- **`lint`**: `actionlint` sobre el workflow, `shellcheck` sobre `scripts/*.sh`, que
  `traefik/dynamic.yml` (`yamllint -d relaxed`) y `consul/consul.json` (`jq`) parseen, y
  [`scripts/test-makefile.sh`](scripts/test-makefile.sh): `make help` lista todos los
  targets, el orden de `make -n up` y `make -n down` (este sin `-v`), que cada
  `docker compose` corra con `env -u CONSUL_HTTP_TOKEN` y que `make check` falle con un
  mensaje claro ante una carpeta inexistente o un `CONSUL_HTTP_TOKEN` vacío. Usa
  carpetas temporales: la CI no clona extract-service ni documents-service.
- **`compose`**: `docker compose config --quiet` resuelve sin errores y `.env` no está versionado.
- **`consul-config`**: `consul validate` de `consul/consul.json` con la misma imagen
  del compose (la toma de `docker compose config`).
- **`smoke`** (después de `lint` y `compose`): `docker compose up -d --wait` (incluye que
  `consul-acl-init` termine bien), Consul con líder, Traefik responde `/ping` con los
  providers ConsulCatalog y File, y pasan `scripts/smoke-acl.sh`,
  `scripts/smoke-traefik.sh` y `scripts/smoke-timeouts.sh`. Si falla, muestra
  `docker compose logs`; siempre termina con `docker compose down -v` (en CI el volumen
  es descartable).

Las imágenes de Consul y Traefik están fijadas por tag **y digest** en el compose.
Para actualizar una versión, cambiar el tag y obtener el digest nuevo con
`docker buildx imagetools inspect <imagen>:<tag>` (campo `Digest`).

## Variables compartidas

Los tres repos usan **estos mismos nombres**. Si se cambia alguno, cambiarlo en todos.
Los **valores** de los tokens, en cambio, son distintos en cada repo (ver
[Qué va en el `.env` de cada repo](#qué-va-en-el-env-de-cada-repo)).

| Variable | Default | La usan | Descripción |
|---|---|---|---|
| `SHARED_NETWORK` | `mired` | infra, extract, documents | Nombre de la red Docker externa compartida. |
| `CONSUL_HTTP_TOKEN` | *(obligatoria, sin default)* | infra, extract, documents | Token de ACL de Consul (UUID). **Un valor distinto en cada repo:** en infra es el de management (solo infra); en extract, el valor de `CONSUL_EXTRACT_TOKEN`; en documents, el de `CONSUL_DOCUMENTS_TOKEN`. Nunca en el repo. |
| `CONSUL_AGENT_TOKEN` | *(obligatoria)* | infra | Token del agente de Consul (policy `agent`). |
| `CONSUL_TRAEFIK_TOKEN` | *(obligatoria)* | infra | Token de Traefik, solo lectura (policy `traefik`). |
| `CONSUL_EXTRACT_TOKEN` | *(obligatoria)* | infra (se copia a extract) | Token de extract (policy `extract`). Va como `CONSUL_HTTP_TOKEN` en el `.env` de extract-service. |
| `CONSUL_DOCUMENTS_TOKEN` | *(obligatoria)* | infra (se copia a documents) | Token de documents (policy `documents`). Va como `CONSUL_HTTP_TOKEN` en el `.env` de documents-service. |
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
make down                # los tres stacks: documents, extract e infra; conserva los volúmenes
docker compose down      # solo infra; conserva los datos (volumen consul_data)
```

`docker compose down -v` borra también el volumen (catálogo y estado de ACL). El
siguiente `up` vuelve a crear las policies y los tokens con los mismos SecretID del
`.env`, pero se pierde todo lo que se haya creado a mano.
La red `mired` no la borra este compose, porque es externa.
