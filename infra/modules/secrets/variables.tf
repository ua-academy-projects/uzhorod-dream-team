variable "config" {
  description = "infra/config.json as a whole; this module uses prefix"
  type = object({
    prefix = string
  })
}

variable "vms" {
  description = "The VMs that exist and the secrets each one reads (modules/service_accounts)"
  type        = map(object({ secrets = list(string) }))
}

variable "members" {
  description = "VM name => its service account as an IAM member (modules/service_accounts)"
  type        = map(string)
}
