# Token de documents-service: registra y desregistra sus instancias de
# "documents". No lee "extract": a extract lo descubre Traefik.
service "documents" {
  policy = "write"
}
