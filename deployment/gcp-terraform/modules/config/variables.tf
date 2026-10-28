variable "config" {
  description = "Unified deployment config"
  type = object({
    google = optional(object({
      project_id = optional(string, "kyiv-air-terraform")
      region     = optional(string, "us-central1")
      zone       = optional(string, "us-central1-a")
    }), {})
    cloudflare = optional(object({
      zone_id = optional(string, "b8efdf9b7667c993aa102a844435ad57")
      domain  = optional(string, "khokhotva.pp.ua")
    }), {})
    vm = map(object({
      private_ip     = string
      public_ip      = optional(bool, false)
      needs_registry = optional(bool, false)
      secrets        = optional(list(string), [])
      tags           = set(string)
      scripts        = list(string)
      entrypoint     = string
      env            = optional(map(string), {})
    }))
    network = object({
      name        = string
      subnet_cidr = string
      enable_nat  = optional(bool, true)
      firewall_rules = map(object({
        source_tags   = optional(set(string), [])
        source_ranges = optional(set(string), [])
        target_tags   = set(string)
        ports         = set(number)
      }))
    })
    application = object({
      postgres_only = bool
      database_name = string
      image_version = string
      ready_timeout = optional(number, 600)
    })
    registry = object({
      repository_id = string
    })
    images = map(string)
    secrets = optional(object({
      passwords = optional(set(string), [])
      versions  = optional(map(string), {})
    }), {})
  })

  validation {
    condition = alltrue([
      for vm in values(var.config.vm) :
      contains(vm.scripts, "common.sh") && contains(vm.scripts, vm.entrypoint) &&
      alltrue([for script in vm.scripts : can(regex("^[a-zA-Z0-9_-]+[.]sh$", script))]) &&
      alltrue([for key, value in vm.env : can(regex("^[A-Z_][A-Z0-9_]*$", key)) && length(regexall("[\\r\\n]", value)) == 0])
    ])
    error_message = "Each VM must list common.sh and its entrypoint, use simple shell filenames, and supply single-line environment values with valid names."
  }
}
