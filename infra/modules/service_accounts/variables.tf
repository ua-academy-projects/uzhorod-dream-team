variable "config" {
  description = "infra/config.json as a whole; this module uses prefix, vm_defaults and the vms' roles"
  type = object({
    prefix = string
    vm_defaults = object({
      roles = optional(list(string), [])
    })
    vms = map(object({
      roles         = optional(list(string), [])
      cloud_logging = optional(bool)
    }))
  })

  validation {
    condition = alltrue([
      for vm in var.config.vms : !coalesce(vm.cloud_logging, var.config.vm_defaults.cloud_logging)
      || contains(concat(var.config.vm_defaults.roles, vm.roles), "roles/logging.logWriter")
    ])
    error_message = "config.json: a VM with cloud_logging needs \"roles/logging.logWriter\" (in its roles or in vm_defaults.roles)."
  }
}

variable "project_id" {
  type = string
}
