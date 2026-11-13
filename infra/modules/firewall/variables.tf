variable "config" {
  type = object({
    project = object({
      name_prefix = string
    })
    access = object({
      admin_cidrs = list(string)
      ssh_port    = optional(number, 22)
    })
    vms = map(object({}))
    app = map(any)
    firewall = list(object({
      from  = string
      to    = string
      ports = list(string)
    }))
  })

  validation {
    condition     = alltrue([for r in var.config.firewall : contains(keys(var.config.vms), r.from) && contains(keys(var.config.vms), r.to)])
    error_message = "firewall: from/to must be keys of vms."
  }

  validation {
    condition     = alltrue([for r in var.config.firewall : alltrue([for p in r.ports : contains(keys(var.config.app), p) && can(tonumber(var.config.app[p]))])])
    error_message = "Every firewall port must name a numeric key of app, e.g. HISTORY_PORT."
  }
}

variable "network_id" {
  type = string
}
