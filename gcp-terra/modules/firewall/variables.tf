variable "network_id" {
  description = "Network ID for firewall rules"
  type        = string
}

variable "config" {
  description = "Firewall rule configuration"

  type = object({
    rules = list(object({
      name               = string
      direction          = optional(string, "INGRESS")
      priority           = optional(number, 1000)
      source_ranges      = optional(list(string), [])
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
}
variable "source_ranges_by_key" {
  description = "External source CIDR lists referenced by rule configuration"
  type        = map(list(string))
  default     = {}
}
