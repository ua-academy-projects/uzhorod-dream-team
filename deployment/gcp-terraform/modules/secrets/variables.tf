variable "project_id" {
  type = string
}

variable "config" {
  type = object({
    passwords = optional(set(string), [])
  })
  description = "Secret generation configuration"
}

variable "vms" {
  type = map(object({
    secrets = optional(set(string), [])
  }))
  description = "VMs and the secrets they need"
  default     = {}
}

variable "service_accounts" {
  type        = map(object({ email = string }))
  description = "VM service accounts used to grant secret access"
  default     = {}
}

variable "payloads" {
  type        = map(string)
  description = "Map of secret names to their values"
  sensitive   = true
  ephemeral   = true
  default     = {}
}

variable "revisions" {
  type        = map(number)
  description = "Map of secret names to their current version number"
  default     = {}
}
