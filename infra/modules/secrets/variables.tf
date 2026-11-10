variable "config" {
  description = "infra/config.json as a whole; this module uses prefix and the secrets of vms.instances"
  type = object({
    prefix = string
    vms = object({
      instances = map(object({
        secrets = optional(list(string), [])
      }))
    })
  })
}

variable "members" {
  description = "VM name => its service account as an IAM member (modules/service_accounts)"
  type        = map(string)
}

