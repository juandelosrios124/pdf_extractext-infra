# Token de Traefik (provider Consul Catalog). Solo lectura: Traefik consulta
# /v1/catalog/services y /v1/health/service/<nombre> (y los watches "services"
# y "checks"). El resultado de health incluye datos del nodo: sin node:read
# Consul filtra las instancias y Traefik no ve ninguna.
service_prefix "" {
  policy = "read"
}

node_prefix "" {
  policy = "read"
}
