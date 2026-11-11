variable "config" {
  description = "infra/config.json as a whole; this module uses prefix, location, network.subnet_cidr, ssh, vms.defaults and its own entry of vms.instances"
  type = object({
    prefix   = string
    location = object({ region = string, zone = string })
    network  = object({ subnet_cidr = string })
    ssh = object({
      user         = string
      bastion_port = number
    })
    vms = object({
      defaults = object({
        machine_type = string
        disk_size_gb = number
        image        = string
      })
      instances = map(object({
        host         = number
        machine_type = optional(string)
        disk_size_gb = optional(number)
        image        = optional(string)
        bastion      = optional(bool, false)
        services     = optional(list(string), [])
        secrets      = optional(list(string), [])
      }))
    })
  })
}

variable "name" {
  description = "Which VM of config.json \"vms.instances\""
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