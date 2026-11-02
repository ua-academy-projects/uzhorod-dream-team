variable "config" {
  description = "config.json; this module reads load_balancer"
  type = object({
    load_balancer = object({
      name              = string
      backend           = string
      health_check_path = string
      domain            = string
    })
  })
}

variable "instances" {
  description = "VMs from the vms module: name => id, zone, private_ip and port"
  type = map(object({
    id         = string
    zone       = string
    private_ip = string
    port       = number
  }))
}
