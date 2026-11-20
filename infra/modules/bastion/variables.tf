variable "config" {
  description = "infra/config.json as a whole: handed to modules/vm as it is; this module itself uses default_cloud, clouds.<cloud>.vms.sizes, vms (defaults, bastion, instances)"
  type        = any

  validation {
    condition = alltrue([
      for cloud in distinct(concat([var.config.default_cloud], [for vm in values(var.config.vms.instances) : try(vm.cloud, var.config.default_cloud)])) :
      can(var.config.clouds[cloud].vms.sizes[try(var.config.vms.bastion.size, var.config.vms.defaults.size)])
    ])
    error_message = "config.json: vms.bastion.size is not in clouds.<cloud>.vms.sizes of a cloud in use."
  }

  validation {
    condition     = !contains([for vm in values(var.config.vms.instances) : vm.host], var.config.vms.bastion.host)
    error_message = "config.json: vms.bastion.host is the host of a VM of vms.instances: give the bastion its own."
  }
}

variable "networks" {
  description = "cloud => { ... } for every cloud with a network (modules/network): a bastion goes into each"
  type        = any
}

variable "secrets" {
  description = "cloud => { secret (its config.json name) => its id there } (modules/secrets)"
  type        = map(map(string))
}
