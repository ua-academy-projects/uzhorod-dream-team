variable "config" {
  description = "VM defaults and per-instance overrides"
  type = object({
    defaults = object({
      machine_type = string
      boot_disk = object({
        image   = string
        size_gb = number
        type    = string
      })
      public_ip              = optional(bool, false)
      attach_service_account = optional(bool, true)
    })
    instances = map(object({
      name                   = string
      machine_type           = optional(string)
      network_ip             = optional(string)
      tags                   = optional(list(string), [])
      public_ip              = optional(bool)
      static_public_ip       = optional(bool, false)
      attach_service_account = optional(bool)
      boot_disk = optional(object({
        image   = optional(string)
        size_gb = optional(number)
        type    = optional(string)
      }), {})
      startup = optional(object({
        type                   = string
        service_role           = optional(string)
        ssh_port               = optional(number, 22)
        tunnel_token_secret_id = optional(string, "")
        ip_https               = optional(bool, false)
      }), { type = "none" })
    }))
  })

  validation {
    condition = alltrue([for vm in values(var.config.instances) :
      !vm.startup.ip_https || (vm.startup.type == "application" && vm.startup.service_role == "ui" && vm.static_public_ip && vm.startup.tunnel_token_secret_id == "")
    ])
    error_message = "IP HTTPS requires the UI application, a static public IP and no tunnel token."
  }

  validation {
    condition = alltrue([for vm in values(var.config.instances) :
      !vm.static_public_ip || coalesce(vm.public_ip, var.config.defaults.public_ip)
    ])
    error_message = "Static public IP requires public_ip = true."
  }

  validation {
    condition = alltrue([for vm in values(var.config.instances) :
      vm.startup.ssh_port >= 1 && vm.startup.ssh_port <= 65535 && floor(vm.startup.ssh_port) == vm.startup.ssh_port
    ])
    error_message = "SSH port must be an integer between 1 and 65535."
  }

  validation {
    condition = alltrue([for vm in values(var.config.instances) :
      contains(["none", "bastion", "application"], vm.startup.type) &&
      (vm.startup.type != "application" || vm.startup.service_role != null)
    ])
    error_message = "Startup type must be none, bastion or application; application requires service_role."
  }
}

variable "project_id" {
  type = string
}
variable "zone" {
  type = string
}
variable "subnet_id" {
  type = string
}
variable "service_account_email" {
  type = string
}

variable "region" {
  description = "Region for reserved public IP addresses"
  type        = string
}
