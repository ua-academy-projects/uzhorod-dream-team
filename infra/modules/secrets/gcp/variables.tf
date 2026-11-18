variable "config" {
  description = "infra/config.json as a whole; this module uses prefix"
  type = object({
    prefix = string
  })
}

variable "vms" {
  description = "name => { identity (its service account e-mail), secrets }"
  type = map(object({
    identity = string
    secrets  = list(string)
  }))
}
