# Token del agente de Consul (acl.tokens.agent). Lo usa el propio agente para
# mantener su nodo en el catalogo (anti-entropy, metadata, coordenadas).
# Docs: https://developer.hashicorp.com/consul/docs/v2.0.x/secure/acl/token/agent
# node:write solo sobre su nodo (node_name "ds" en consul/consul.json).
node "ds" {
  policy = "write"
}

# service:read: el agente lee los servicios del catalogo durante el sync.
service_prefix "" {
  policy = "read"
}
