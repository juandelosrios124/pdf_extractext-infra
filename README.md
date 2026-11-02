# pdf_extractext-infra

Infraestructura compartida de los microservicios de pdf_extractext:
la red Docker `mired` y Consul (service discovery y health checks).

- [extract-service](https://github.com/juandelosrios124/extract-service)
- [documents-service](https://github.com/OlivettiSantino/documents-service)

## Levantar Consul

```bash
# 1. Red compartida (una sola vez por máquina; la usan los tres repos)
docker network create mired

# 2. Variables: completar CONSUL_HTTP_TOKEN con un UUID (uuidgen)
cp .env.example .env

# 3. Consul
docker compose up -d
docker compose ps        # consul debe quedar (healthy)
```

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

## Variables compartidas

Los tres repos usan **estos mismos nombres**. Si se cambia alguno, cambiarlo en todos.

| Variable | Default | La usan | Descripción |
|---|---|---|---|
| `SHARED_NETWORK` | `mired` | infra, extract, documents | Nombre de la red Docker externa compartida. |
| `CONSUL_HTTP_TOKEN` | *(obligatoria, sin default)* | infra, extract, documents | Token de ACL de Consul (UUID, `uuidgen`). Mismo valor en los tres `.env`; nunca en el repo. |
| `CONSUL_HTTP_ADDR` | `http://consul:8500` | extract, documents | URL de Consul desde la red `mired`. |
| `CONSUL_ENABLED` | `false` | extract, documents | Activa el registro/discovery. Sin Consul los servicios funcionan igual. |
| `CONSUL_UI_PORT` | `8500` | infra | Puerto del host para la UI/API, siempre en `127.0.0.1`. |

`CONSUL_HTTP_ADDR` y `CONSUL_HTTP_TOKEN` son los nombres estándar que reconoce la CLI de `consul`.

## Apagar

```bash
docker compose down      # conserva los datos (volumen consul_data)
```

`docker compose down -v` borra también el volumen (catálogo y estado de ACL).
La red `mired` no la borra este compose, porque es externa.
