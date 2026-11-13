variable "config" {
  type = object({
    project = object({
      id          = string
      name_prefix = string
    })
    vms = map(object({
      service_account = optional(bool, false)
      bastion         = optional(bool, false)
    }))
    app = object({
      POSTGRES_BACKEND = string
    })
    monitoring = object({
      ops_agent = bool
    })
  })

  validation {
    condition = alltrue([
      for k, v in var.config.vms : can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", "${var.config.project.name_prefix}-${k}"))
      if v.service_account || var.config.monitoring.ops_agent || !v.bastion
    ])
    error_message = "Service account IDs <name_prefix>-<key> must be 6-30 characters of a-z, 0-9 and -, starting with a letter; shorten project.name_prefix or the VM key."
  }

  validation {
    condition = alltrue([
      for k, v in var.config.vms : length("${var.config.project.name_prefix}-${k}@${var.config.project.id}.iam") <= 63
      if v.service_account
    ])
    error_message = "Database user names <name_prefix>-<key>@<project.id>.iam must be at most 63 characters; shorten project.name_prefix or project.id."
  }
}

variable "vm_keys" {
  type = set(string)
}
