variable "config" {
  description = "Shared configuration; this module selects its own settings."
  type = object({
    firewall = object({
      rules = list(object({
        name               = string
        direction          = optional(string, "INGRESS")
        priority           = optional(number, 1000)
        source_ranges      = optional(list(string), [])
        source_tags        = optional(list(string), [])
        enabled            = optional(bool, true)
        source_ranges_key  = optional(string)
        destination_ranges = optional(list(string), [])
        target_tags        = optional(list(string), [])

        allowed = optional(list(object({
          protocol = string
          ports    = optional(list(string), [])
        })), [])

        denied = optional(list(object({
          protocol = string
          ports    = optional(list(string), [])
        })), [])
      }))
    })
    database = object({ provider = string, name = string })
    compute  = object({ application = object({ app_backend = string }) })
  })
}
variable "network_id" { type = string }
variable "admin_ip_cidr" {
  type      = string
  default   = null
  sensitive = true
}
