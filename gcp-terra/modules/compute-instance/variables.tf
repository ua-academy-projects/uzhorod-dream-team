variable "config" {
  description = "VM defaults and per-instance overrides"
  type = object({
    application = object({
      repo_url    = string
      repo_branch = string
      app_backend = string
    })
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
        type         = string
        service_role = optional(string)
        ssh_port     = optional(number, 22)
        ip_https     = optional(bool, false)
      }), { type = "none" })
    }))
  })

  validation {
    condition     = contains(["hybrid", "postgres"], var.config.application.app_backend)
    error_message = "compute.application.app_backend must be hybrid or postgres."
  }
  validation {
    condition     = alltrue([for vm in values(var.config.instances) : contains(["none", "bastion"], vm.startup.type)])
    error_message = "Only initial bastion SSH bootstrap is supported; application deployment belongs to Ansible."
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
variable "service_account_emails" {
  type = map(string)
}

variable "region" {
  description = "Region for reserved public IP addresses"
  type        = string
}

variable "database_provider" {
  type = string
  validation {
    condition     = contains(["cloud_sql", "container"], var.database_provider)
    error_message = "database_provider must be cloud_sql or container."
  }
}
