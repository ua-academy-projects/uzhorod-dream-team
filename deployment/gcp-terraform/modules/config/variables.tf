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
    secrets = optional(object({
      passwords = optional(set(string), [])
    }), {})
  })
}
