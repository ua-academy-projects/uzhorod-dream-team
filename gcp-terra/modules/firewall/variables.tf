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
        destination_ranges = optional(list(string), [])
        target_tags        = optional(list(string), [])

        allowed = optional(list(object({
          protocol  = string
          ports     = optional(list(string), [])
          port_keys = optional(list(string), [])
        })), [])

        denied = optional(list(object({
          protocol = string
          ports    = optional(list(string), [])
        })), [])
      }))
    })
    database = object({ provider = string, name = string })
    ports    = map(number)
    compute = object({
      application = object({ app_backend = string })
      instances   = object({ bastion = object({ startup = object({ ssh_port = number }) }) })
    })
  })

  validation {
    condition = alltrue(flatten([
      for rule in var.config.firewall.rules : [
        for allow in rule.allowed : alltrue([
          for key in allow.port_keys : contains(concat(keys(var.config.ports), ["bastion_ssh"]), key)
        ])
      ]
    ]))
    error_message = "Firewall port_keys must reference config.ports or bastion_ssh."
  }
  validation {
    condition     = alltrue([for port in values(var.config.ports) : port >= 1 && port <= 65535 && floor(port) == port])
    error_message = "Shared ports must be integers between 1 and 65535."
  }
  validation {
    condition     = length(distinct([for rule in var.config.firewall.rules : rule.name])) == length(var.config.firewall.rules)
    error_message = "Firewall rule names must be unique."
  }
  validation {
    condition     = alltrue([for rule in var.config.firewall.rules : contains(["INGRESS", "EGRESS"], rule.direction) && rule.priority >= 0 && rule.priority <= 65535 && floor(rule.priority) == rule.priority])
    error_message = "Firewall rules require INGRESS/EGRESS and an integer priority between 0 and 65535."
  }
  validation {
    condition     = alltrue([for rule in var.config.firewall.rules : (length(rule.allowed) > 0) != (length(rule.denied) > 0)])
    error_message = "Each firewall rule must contain either allowed or denied entries, never both or neither."
  }
  validation {
    condition = alltrue(flatten([for rule in var.config.firewall.rules : [
      for cidr in concat(rule.source_ranges, rule.destination_ranges) : can(cidrhost(cidr, 0))
    ]]))
    error_message = "Firewall source_ranges and destination_ranges must contain valid CIDRs."
  }
  validation {
    condition = alltrue(flatten([for rule in var.config.firewall.rules : concat(
      [for entry in rule.allowed : !contains(["tcp", "udp"], entry.protocol) || length(entry.ports) + length(entry.port_keys) > 0],
      [for entry in rule.denied : !contains(["tcp", "udp"], entry.protocol) || length(entry.ports) > 0]
    )]))
    error_message = "TCP/UDP firewall entries must explicitly list ports; empty lists allow or deny every port."
  }
}
variable "network_id" { type = string }
