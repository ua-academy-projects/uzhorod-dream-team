variable "config" {
  description = "Shared configuration; this module selects its own settings."
  type = object({
    region = string
    network = object({
      name = string

      subnet = object({
        name   = string
        cidr   = string
        region = string
      })

      nat = object({
        name    = string
        enabled = optional(bool, true)
      })
    })
  })
  validation {
    condition     = can(cidrnetmask(var.config.network.subnet.cidr))
    error_message = "network.subnet.cidr must be a valid IPv4 CIDR."
  }
  validation {
    condition     = var.config.network.subnet.region == var.config.region
    error_message = "The application subnet must be in the configured region."
  }
}
