variable "config" {
  description = "firewall part of config.json: rules for every backend (common) and per backend (postgres, redis)"
  type = object({
    common   = map(object({ protocol = optional(string, "tcp"), ports = list(string), source_ranges = optional(list(string)), source_tags = optional(list(string)), target_tags = list(string) }))
    postgres = map(object({ protocol = optional(string, "tcp"), ports = list(string), source_ranges = optional(list(string)), source_tags = optional(list(string)), target_tags = list(string) }))
    redis    = map(object({ protocol = optional(string, "tcp"), ports = list(string), source_ranges = optional(list(string)), source_tags = optional(list(string)), target_tags = list(string) }))
  })

  validation {
    condition = alltrue([
      for rule in concat(values(var.config.common), values(var.config.postgres), values(var.config.redis)) :
      length(coalesce(rule.source_ranges, [])) + length(coalesce(rule.source_tags, [])) > 0
    ])
    error_message = "Every firewall rule needs source_ranges or source_tags."
  }

  validation {
    condition = alltrue([
      for rule in concat(values(var.config.common), values(var.config.postgres), values(var.config.redis)) :
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
