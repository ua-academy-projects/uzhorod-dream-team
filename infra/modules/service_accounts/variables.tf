variable "config" {
  description = "infra/config.json as a whole; this module uses prefix, vms, app (the queue and cache switches) and database (type, vm)"
  type = object({
    prefix = string
    vms = object({
      defaults = object({
        cloud_logging = bool
        roles         = optional(list(string), [])
      })
      instances = map(object({
        bastion       = optional(bool, false)
        cloud_logging = optional(bool)
        services      = optional(list(string), [])
        secrets       = optional(list(string), [])
        roles         = optional(list(string), [])
      }))
    })
    app = object({
      queue_backend = string
      cache_backend = string
    })
    database = object({
      type = string
      vm   = string
    })
  })

  validation {
    condition = alltrue([
      for vm in var.config.vms.instances : !coalesce(vm.cloud_logging, var.config.vms.defaults.cloud_logging)
      || contains(concat(var.config.vms.defaults.roles, vm.roles), "roles/logging.logWriter")
    ])
    error_message = "config.json: a VM with cloud_logging needs \"roles/logging.logWriter\" (in its roles or in vms.defaults.roles)."
  }

  validation {
    condition     = contains(keys(var.config.vms.instances), var.config.database.vm) && !try(var.config.vms.instances[var.config.database.vm].bastion, false)
    error_message = "config.json: database.vm must be a VM of vms.instances, and not the bastion."
  }
}

variable "project_id" {
  type = string
}