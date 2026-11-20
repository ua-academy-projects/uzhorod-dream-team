variable "config" {
  description = "infra/config.json as a whole; this module uses prefix, default_cloud, region, zone, clouds.<cloud> (location, network, vms, iam), ssh, vms and database (type, vm)"
  type = object({
    prefix        = string
    default_cloud = string
    region        = string
    zone          = string
    clouds        = any # each cloud's tables have their own shape (an image is a name in GCP, an owner and a name in AWS)
    ssh = object({
      user         = string
      bastion_port = number
    })
    vms = object({
      defaults = object({
        size          = string
        disk_type     = string
        disk_gb       = number
        os            = string
        cloud_logging = bool
        permissions   = list(string)
      })
      instances = map(object({
        host          = number
        cloud         = optional(string)
        bastion       = optional(bool, false)
        size          = optional(string)
        disk_type     = optional(string)
        disk_gb       = optional(number)
        os            = optional(string)
        cloud_logging = optional(bool)
        permissions   = optional(list(string), [])
        secrets       = optional(list(string), [])
      }))
    })
    database = object({
      type = string
      vm   = string
    })
  })

  validation {
    condition     = alltrue([for vm in values(var.config.vms.instances) : coalesce(vm.cloud, var.config.default_cloud) == "gcp"])
    error_message = "config.json: VMs are built only in \"gcp\" so far (default_cloud and every VM's \"cloud\")."
  }

  # The VMs together

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


  validation {
    condition = alltrue([
      for vm in values(var.config.vms.instances) :
      can(var.config.clouds[coalesce(vm.cloud, var.config.default_cloud)].vms.sizes[coalesce(vm.size, var.config.vms.defaults.size)])
    ])
    error_message = "config.json: a size of vms is not in clouds.<its cloud>.vms.sizes."
  }

  validation {
    condition = alltrue([
      for vm in values(var.config.vms.instances) :
      can(var.config.clouds[coalesce(vm.cloud, var.config.default_cloud)].vms.disk_types[coalesce(vm.disk_type, var.config.vms.defaults.disk_type)])
    ])
    error_message = "config.json: a disk_type of vms is not in clouds.<its cloud>.vms.disk_types."
  }

  validation {
    condition = alltrue([
      for vm in values(var.config.vms.instances) :
      can(var.config.clouds[coalesce(vm.cloud, var.config.default_cloud)].vms.os[coalesce(vm.os, var.config.vms.defaults.os)])
    ])
    error_message = "config.json: an os of vms is not in clouds.<its cloud>.vms.os."
  }

  validation {
    condition = alltrue([
      for vm in values(var.config.vms.instances) : alltrue([
        for permission in concat(var.config.vms.defaults.permissions, vm.permissions) :
        can(var.config.clouds[coalesce(vm.cloud, var.config.default_cloud)].iam.permissions[permission])
      ])
    ])
    error_message = "config.json: a permission of vms is not in clouds.<its cloud>.iam.permissions."
  }
}

variable "secrets" {
  description = "cloud => { secret (its config.json name) => its id there } (modules/secrets): each VM grants itself access to its own"
  type        = map(map(string))
}

variable "networks" {
  description = "cloud => { subnet_id, firewall = { bastion = [...], vm = [...] }, ... } (modules/network; each cloud has its own extras)"
  type        = any
}
