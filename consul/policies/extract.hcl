# Token de extract-service: cada replica registra y desregistra su instancia
# del servicio "extract" (y su check). Ningun otro nombre.
service "extract" {
  policy = "write"
}
