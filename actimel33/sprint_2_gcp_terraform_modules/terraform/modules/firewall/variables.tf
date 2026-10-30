variable "config" {
  description = "firewall part of config.json: group (common for every backend, postgres, redis) => rule name => rule"
  type = map(map(object({
    protocol      = string
    ports         = list(string)
    source_ranges = optional(list(string))
    source_tags   = optional(list(string))
    target_tags   = list(string)
  })))

  validation {
    condition = alltrue([
      for rule in flatten([for group in values(var.config) : values(group)]) :
      length(coalesce(rule.source_ranges, [])) + length(coalesce(rule.source_tags, [])) > 0
    ])
    error_message = "Every firewall rule needs source_ranges or source_tags."
  }

  validation {
    condition = alltrue([
      for rule in flatten([for group in values(var.config) : values(group)]) :
      !contains(coalesce(rule.source_ranges, []), "0.0.0.0/0")
    ])
    error_message = "Firewall rules must not be open to 0.0.0.0/0."
  }
}

variable "backend" {
  description = "Queue backend of the app: postgres or redis"
  type        = string

  validation {
    condition     = contains(["postgres", "redis"], var.backend)
    error_message = "backend must be postgres or redis."
  }
}

variable "network" {
  description = "Self link of the VPC"
  type        = string
}
