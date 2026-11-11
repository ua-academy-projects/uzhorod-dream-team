variable "config" {
  description = "Shared configuration; this module selects its own settings."
  type = object({
    project_id = string
    zone       = string
    region     = string
    database   = object({ provider = string, name = string })
    compute = object({
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
  })
  validation {
    condition     = contains(["hybrid", "postgres"], var.config.compute.application.app_backend)
    error_message = "compute.application.app_backend must be hybrid or postgres."
  }
  validation {
    condition     = alltrue([for vm in values(var.config.compute.instances) : contains(["none", "bastion"], vm.startup.type)])
    error_message = "Only initial bastion SSH bootstrap is supported; applications are managed by Ansible."
  }
  validation {
    condition     = contains(["cloud_sql", "container"], var.config.database.provider)
    error_message = "database.provider must be cloud_sql or container."
  }
}
variable "subnet_id" { type = string }
variable "service_account_emails" { type = map(string) }
