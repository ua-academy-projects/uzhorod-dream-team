variable "cfg" {
  type = object({
    google = object({
      project_id = string
    })
    secrets = object({
      passwords = optional(set(string), [])
    })
    vm = object({
      instances = map(object({
        secrets = optional(set(string), [])
      }))
    })
  })
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
