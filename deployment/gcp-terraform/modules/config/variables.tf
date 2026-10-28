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
      machine_type = string
      boot_disk = object({
        image   = string
        size_gb = number
        type    = string
      })
      data_disk = optional(object({
        size_gb     = number
        type        = string
        device_name = string
      }))
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
      name                = string
      subnet_cidr         = string
      enable_nat          = optional(bool, true)
      public_network_tier = optional(string, "STANDARD")
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
}
