variable "config" {
  description = "config.json; this module reads secrets (secret ID => password length, version and the VMs that may read it) and the VM names in vms.machines"
  type = object({
    secrets = map(object({
      length  = number
      version = optional(number, 1)
      readers = list(string)
    }))
    vms = any
  })

  validation {
    condition     = alltrue([for secret in values(var.config.secrets) : secret.length >= 16])
    error_message = "Passwords must be at least 16 characters long."
  }

  validation {
    condition     = alltrue([for secret in values(var.config.secrets) : length(setsubtract(secret.readers, keys(var.config.vms.machines))) == 0])
    error_message = "secrets.<id>.readers may only name VMs from vms.machines."
  }
}

variable "readers" {
  description = "VM name => email of its service account, for the VMs created for this backend (from the vms module)"
  type        = map(string)
}
