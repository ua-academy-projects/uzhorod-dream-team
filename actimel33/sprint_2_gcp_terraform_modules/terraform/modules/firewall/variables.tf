variable "network_name" {
  description = "Name of the VPC network rules are attached"
  type        = string
}

variable "rules" {
  description = "Rule name => protocol, ports, sources (IP ranges or network tags) and target network tags"
  type = map(object({
    protocol      = optional(string, "tcp")
    ports         = list(string)
    source_ranges = optional(list(string))
    source_tags   = optional(list(string))
    target_tags   = list(string)
  }))

  validation {
    condition     = alltrue([for rule in values(var.rules) : length(coalesce(rule.source_ranges, [])) + length(coalesce(rule.source_tags, [])) > 0])
    error_message = "Every firewall rule needs source_ranges or source_tags."
  }

  validation {
    condition     = alltrue([for rule in values(var.rules) : !contains(coalesce(rule.source_ranges, []), "0.0.0.0/0")])
    error_message = "Firewall rules must not be open to 0.0.0.0/0."
  }
}
