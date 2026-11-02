variable "config" {
  description = "config.json; this module reads app.backend and firewall: group (common for every backend, postgres, redis) => rule name => rule"
  type = object({
    app = object({ backend = string })
    firewall = map(map(object({
      protocol      = string
      ports         = list(string)
      source_ranges = optional(list(string))
      source_tags   = optional(list(string))
      target_tags   = list(string)
    })))
  })

  validation {
    condition     = contains(["postgres", "redis"], var.config.app.backend)
    error_message = "app.backend must be postgres or redis."
  }

  validation {
    condition = alltrue([
      for rule in flatten([for group in values(var.config.firewall) : values(group)]) :
      length(coalesce(rule.source_ranges, [])) + length(coalesce(rule.source_tags, [])) > 0
    ])
    error_message = "Every firewall rule needs source_ranges or source_tags."
  }

  validation {
    condition = alltrue([
      for rule in flatten([for group in values(var.config.firewall) : values(group)]) :
      !contains(coalesce(rule.source_ranges, []), "0.0.0.0/0")
    ])
    error_message = "Firewall rules must not be open to 0.0.0.0/0."
  }
}

variable "network" {
  description = "Self link of the VPC"
  type        = string
}
