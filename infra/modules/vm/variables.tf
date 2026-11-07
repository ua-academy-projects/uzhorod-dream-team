variable "config" {
  description = "infra/config.json as a whole; this module uses prefix, location, network.subnet_cidr, ssh, vm_defaults and its own entry of vms"
  type = object({
    prefix   = string
    location = object({ region = string, zone = string })
    network  = object({ subnet_cidr = string })
    ssh      = object({ user = string, user_public_key_file = string, internal_public_key_file = string })
    vm_defaults = object({
      machine_type = string
      disk_size_gb = number
      image        = string
    })
    vms = map(object({
      host         = number
      machine_type = optional(string)
      disk_size_gb = optional(number)
      image        = optional(string)
      bastion      = optional(bool, false)
      secrets      = optional(list(string), [])
    }))
  })

  validation {
    condition     = alltrue([for vm in var.config.vms : !vm.bastion || contains(vm.secrets, "internal-ssh-key")])
    error_message = "config.json: the bastion needs \"internal-ssh-key\" in its \"secrets\"."
  }
}

variable "name" {
  description = "Which VM of config.json \"vms\""
  type        = string
}

variable "subnetwork_id" {
  type = string
}

variable "bastion_tag" {
  description = "The network tag the firewall opens SSH for (modules/network)"
  type        = string
}

variable "service_account" {
  description = "E-mail of the account the VM runs as (modules/service_accounts)"
  type        = string
}

variable "labels" {
  type = map(string)
}