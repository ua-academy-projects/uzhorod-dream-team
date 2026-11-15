variable "config" {
  description = "Shared configuration; this module selects its own settings."
  type = object({
    project_id = string
    zone       = string
    region     = string
    network    = object({ subnet = object({ cidr = string }) })
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
          type     = string
          ssh_port = optional(number, 22)
          ip_https = optional(bool, false)
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
  validation {
    condition     = startswith(var.config.zone, "${var.config.region}-")
    error_message = "The Compute zone must belong to the configured region."
  }
  validation {
    condition     = length(distinct([for vm in values(var.config.compute.instances) : vm.name])) == length(var.config.compute.instances)
    error_message = "Compute instance names must be unique."
  }
  validation {
    condition     = length(distinct(compact([for vm in values(var.config.compute.instances) : vm.network_ip]))) == length(compact([for vm in values(var.config.compute.instances) : vm.network_ip]))
    error_message = "Explicit Compute private IP addresses must be unique."
  }
  validation {
    condition = alltrue([for vm in values(var.config.compute.instances) : vm.network_ip == null ? true : try(
      cidrhost("${vm.network_ip}/${split("/", var.config.network.subnet.cidr)[1]}", 0) == cidrhost(var.config.network.subnet.cidr, 0), false
    )])
    error_message = "Every explicit Compute private IP must belong to network.subnet.cidr."
  }
  validation {
    condition = alltrue([for vm in values(var.config.compute.instances) :
      !vm.static_public_ip || coalesce(vm.public_ip, var.config.compute.defaults.public_ip)
    ])
    error_message = "A static public IP requires public_ip=true on the VM or in compute.defaults."
  }
  validation {
    condition = alltrue([for vm in values(var.config.compute.instances) :
      coalesce(vm.boot_disk.size_gb, var.config.compute.defaults.boot_disk.size_gb) >= 10 &&
      floor(coalesce(vm.boot_disk.size_gb, var.config.compute.defaults.boot_disk.size_gb)) == coalesce(vm.boot_disk.size_gb, var.config.compute.defaults.boot_disk.size_gb)
    ])
    error_message = "Boot disk sizes must be integers of at least 10 GB."
  }
  validation {
    condition     = alltrue([for vm in values(var.config.compute.instances) : vm.startup.ssh_port >= 1 && vm.startup.ssh_port <= 65535 && floor(vm.startup.ssh_port) == vm.startup.ssh_port])
    error_message = "Bootstrap SSH ports must be integers between 1 and 65535."
  }
}
variable "subnet_id" { type = string }
variable "service_account_emails" { type = map(string) }
