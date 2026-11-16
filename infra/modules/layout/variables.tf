variable "config" {
  description = "infra/config.json as a whole; this module uses vms, app (the switches) and database (type, vm)"
  type = object({
    vms = object({
      defaults = object({
        size          = string
        os            = string
        disk_gb       = number
        cloud_logging = bool
        permissions   = list(string)
      })
      instances = map(object({
        host          = number
        bastion       = optional(bool, false)
        size          = optional(string)
        os            = optional(string)
        disk_gb       = optional(number)
        cloud_logging = optional(bool)
        permissions   = optional(list(string), [])
        services      = optional(list(string), [])
        secrets       = optional(list(string), [])
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
    condition     = length([for vm in values(var.config.vms.instances) : vm if vm.bastion]) == 1
    error_message = "config.json: exactly one VM of vms.instances must have \"bastion\": true."
  }

  validation {
    condition     = length(distinct([for vm in values(var.config.vms.instances) : vm.host])) == length(var.config.vms.instances)
    error_message = "config.json: every VM of vms.instances needs its own host number."
  }

  validation {
    condition     = try(!var.config.vms.instances[var.config.database.vm].bastion, false)
    error_message = "config.json: database.vm must be one of vms.instances, and not the bastion."
  }

  validation {
    condition = alltrue([
      for service, on in { rabbitmq = var.config.app.queue_backend == "rabbitmq", redis = var.config.app.cache_backend == "redis" } :
      !on || anytrue([for vm in values(var.config.vms.instances) : contains(vm.services, service)])
    ])
    error_message = "config.json: app switches the queue to rabbitmq or the cache to redis, but no VM of vms.instances lists that service."
  }

  validation {
    condition     = alltrue([for vm in values(var.config.vms.instances) : !vm.bastion || contains(vm.secrets, "ssh-host-key")])
    error_message = "config.json: the bastion needs \"ssh-host-key\" in its \"secrets\" (it reads its SSH host key from there at boot)."
  }

  validation {
    condition = alltrue([
      for vm in values(var.config.vms.instances) : !coalesce(vm.cloud_logging, var.config.vms.defaults.cloud_logging)
      || contains(concat(var.config.vms.defaults.permissions, vm.permissions), "write_logs")
    ])
    error_message = "config.json: a VM with cloud_logging needs the permission \"write_logs\" (in its permissions or in vms.defaults.permissions)."
  }
}
