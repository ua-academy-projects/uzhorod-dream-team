variable "config" {
  description = "infra/config.json as a whole; this module uses prefix, default_cloud, region, zone, clouds.<cloud> (location, network, vms, iam), ssh, vms (defaults, bastion, instances) and database (type, vm)"
  type = object({
    prefix        = string
    default_cloud = string
    region        = string
    zone          = string
    clouds        = any
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
      bastion = object({
        host      = number
        size      = optional(string)
        disk_type = optional(string)
        disk_gb   = optional(number)
        os        = optional(string)
      })
      instances = map(object({
        host          = number
        cloud         = optional(string)
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

  # The VMs together

  validation {
    condition     = !contains(keys(var.config.vms.instances), "bastion")
    error_message = "config.json: the bastion is built by default in every cloud: remove it from vms.instances (its settings: vms.bastion)."
  }

  validation {
    condition     = !contains([for vm in values(var.config.vms.instances) : vm.host], var.config.vms.bastion.host)
    error_message = "config.json: vms.bastion.host is the host of a VM of vms.instances: give the bastion its own."
  }

  validation {
    condition     = length(distinct([for vm in values(var.config.vms.instances) : vm.host])) == length(var.config.vms.instances)
    error_message = "config.json: every VM of vms.instances needs its own host number."
  }

  validation {
    condition     = contains(keys(var.config.vms.instances), var.config.database.vm)
    error_message = "config.json: database.vm must be one of vms.instances."
  }

  validation {
    condition = alltrue([
      for vm in values(var.config.vms.instances) : !coalesce(vm.cloud_logging, var.config.vms.defaults.cloud_logging)
      || contains(concat(var.config.vms.defaults.permissions, vm.permissions), "write_logs")
    ])
    error_message = "config.json: a VM with cloud_logging needs the permission \"write_logs\" (in its permissions or in vms.defaults.permissions)."
  }

  # The words of every VM must be in the tables of its cloud

  validation {
    condition = alltrue([
      for vm in values(var.config.vms.instances) :
      can(var.config.clouds[coalesce(vm.cloud, var.config.default_cloud)].vms.sizes[coalesce(vm.size, var.config.vms.defaults.size)])
    ])
    error_message = "config.json: a size of vms is not in clouds.<its cloud>.vms.sizes."
  }

  validation {
    condition = alltrue([
      for cloud in distinct(concat([var.config.default_cloud], [for vm in values(var.config.vms.instances) : coalesce(vm.cloud, var.config.default_cloud)])) :
      can(var.config.clouds[cloud].vms.sizes[coalesce(var.config.vms.bastion.size, var.config.vms.defaults.size)])
    ])
    error_message = "config.json: vms.bastion.size is not in clouds.<cloud>.vms.sizes of a cloud in use (every cloud in use gets a bastion)."
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
  description = "cloud => { network_id, subnet_id, firewall = { bastion = [...], vm = [...] }, ... } for every cloud with a network (modules/network; each cloud has its own extras): a bastion goes into each"
  type        = any
}
