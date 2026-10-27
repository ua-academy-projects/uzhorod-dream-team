variable "secrets" {
  description = "Secret ID => password length, version and VMs that may read it (secrets in config.json)"
  type = map(object({
    length  = number
    version = optional(number, 1)
    readers = list(string)
  }))

  validation {
    condition     = alltrue([for secret in values(var.secrets) : secret.length >= 16])
    error_message = "Passwords must be at least 16 characters long."
  }
}

variable "reader_emails" {
  description = "VM name => email of its service account (from the iam module)"
  type        = map(string)
}
