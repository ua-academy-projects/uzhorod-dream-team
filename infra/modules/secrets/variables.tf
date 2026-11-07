variable "config" {
  description = "infra/config.json as a whole; this module uses prefix and the vms' secrets"
  type = object({
    prefix = string
    vms = map(object({
      secrets = optional(list(string), [])
    }))
  })
}

variable "members" {
  description = "VM name => its service account as an IAM member (modules/service_accounts)"
  type        = map(string)
}

variable "labels" {
  type = map(string)
}
