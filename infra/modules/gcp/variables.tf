variable "config" {
  description = "infra/config.json as a whole; each submodule declares the part it uses. Here: the generic words must be in the tables of clouds.gcp"
  type        = any

  validation {
    condition = alltrue([
      for size in concat([var.config.vms.defaults.size], [for vm in values(var.config.vms.instances) : try(vm.size, null) if try(vm.size, null) != null]) :
      contains(keys(var.config.clouds.gcp.sizes), size)
    ])
    error_message = "config.json: a size of vms is missing from clouds.gcp.sizes."
  }

  validation {
    condition = alltrue([
      for os in concat([var.config.vms.defaults.os], [for vm in values(var.config.vms.instances) : try(vm.os, null) if try(vm.os, null) != null]) :
      contains(keys(var.config.clouds.gcp.os), os)
    ])
    error_message = "config.json: an os of vms is missing from clouds.gcp.os."
  }

  validation {
    condition = alltrue([
      for permission in flatten(concat([var.config.vms.defaults.permissions], [for vm in values(var.config.vms.instances) : try(vm.permissions, [])])) :
      contains(keys(var.config.clouds.gcp.permissions), permission)
    ])
    error_message = "config.json: a permission of vms is missing from clouds.gcp.permissions."
  }

  validation {
    condition     = var.config.database.type != "managed" || contains(keys(var.config.clouds.gcp.database_sizes), try(var.config.database.managed.size, ""))
    error_message = "config.json: database.managed.size is missing from clouds.gcp.database_sizes."
  }
}

variable "vms" {
  description = "The VMs to build and what runs on each (modules/layout)"
  type = map(object({
    host          = number
    bastion       = bool
    size          = string
    os            = string
    disk_gb       = number
    cloud_logging = bool
    permissions   = list(string)
    services      = list(string)
    secrets       = list(string)
  }))
}

variable "ssh_allowed_cidrs" {
  description = "Who may SSH to the bastion"
  type        = list(string)
}

variable "project_id" {
  description = "The GCP project (envs/gcp)"
  type        = string
}
