variable "project_id" {
  type = string
}

variable "secrets_to_set" {
  type        = set(string)
  description = "Set of secret names to set"
  default     = []
}

variable "vm_access" {
  type = map(object({
    email   = string
    secrets = list(string)
  }))
  description = "Map of VM to their secrets and service email"
  default     = {}
}

variable "payloads" {
  type        = map(string)
  description = "Map of secret names to their values"
  sensitive   = true
  ephemeral   = true
}

variable "revisions" {
  type        = map(number)
  description = "Map of secret names to their current version number"
  default     = {}
}
