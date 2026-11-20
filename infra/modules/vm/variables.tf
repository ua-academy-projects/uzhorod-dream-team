variable "config" {
  description = "infra/config.json as a whole; this module uses prefix, default_cloud, region, zone, clouds.<cloud> (location, network, vms, iam), ssh, vms (defaults; instances for the checks) and database (type, vm)"
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

  # The VMs together

  validation {
    condition     = !anytrue([for vm in values(var.config.vms.instances) : vm.bastion])
    error_message = "config.json: the bastion is built by default in every cloud now: remove it from vms.instances (its settings: vms.bastion)."
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

variable "instances" {
  description = "The VMs to build: config.json vms.instances (envs/dev), or the bastion of one cloud (modules/bastion)"
  type = map(object({
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
}

variable "bastions" {
  description = "cloud => { external_ip, ... }: the bastion each VM is reached through (modules/bastion; {} when building the bastions themselves)"
  type        = any
  default     = {}
}

variable "secrets" {
  description = "cloud => { secret (its config.json name) => its id there } (modules/secrets): each VM grants itself access to its own"
  type        = map(map(string))
}

variable "networks" {
  description = "cloud => { subnet_id, firewall = { bastion = [...], vm = [...] }, ... } (modules/network; each cloud has its own extras)"
  type        = any
}
