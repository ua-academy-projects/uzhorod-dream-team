variable "config" {
  description = "infra/config.json as a whole; this module uses prefix"
  type = object({
    prefix = string
  })
}

variable "vms" {
  description = "name => { cloud, identity, secrets }: where each VM is, who it is there and which secrets it reads (modules/vm)"
  type = map(object({
    cloud    = string
    identity = string
    secrets  = list(string)
  }))
}
