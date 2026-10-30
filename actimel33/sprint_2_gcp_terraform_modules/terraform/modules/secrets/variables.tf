variable "config" {
  description = "secrets part of config.json: secret ID => password length, version and the VMs that may read it"
  type = map(object({
    length  = number
    version = optional(number, 1)
    readers = list(string)
  }))

  validation {
    condition     = alltrue([for secret in values(var.config) : secret.length >= 16])
    error_message = "Passwords must be at least 16 characters long."
  }
}

variable "readers" {
  description = "VM name => email of its service account (from the vms module)"
  type        = map(string)
}
