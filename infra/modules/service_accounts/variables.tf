variable "config" {
  description = "infra/config.json as a whole; this module uses prefix and the roles of vms.defaults and vms.instances"
  type = object({
    prefix = string
    vms = object({
      defaults = object({
        cloud_logging = bool
        roles         = optional(list(string), [])
      })
      instances = map(object({
        cloud_logging = optional(bool)
        roles         = optional(list(string), [])
      }))
    })
  })

  validation {
    condition = alltrue([
      for vm in var.config.vms.instances : !coalesce(vm.cloud_logging, var.config.vms.defaults.cloud_logging)
      || contains(concat(var.config.vms.defaults.roles, vm.roles), "roles/logging.logWriter")
    ])
    error_message = "config.json: a VM with cloud_logging needs \"roles/logging.logWriter\" (in its roles or in vms.defaults.roles)."
  }
}

variable "project_id" {
  type = string
}