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
      needs_registry = optional(bool, false)
      secrets        = optional(list(string), [])
    }))
    secrets = optional(object({
      passwords = optional(set(string), [])
    }), {})
  })
}
