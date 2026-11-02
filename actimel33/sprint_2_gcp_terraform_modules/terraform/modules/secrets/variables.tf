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

  validation {
    condition     = alltrue([for secret in values(var.config) : length(setsubtract(secret.readers, var.vm_names)) == 0])
    error_message = "secrets.<id>.readers may only name VMs from vms.machines."
  }
}

variable "readers" {
  description = "VM name => email of its service account, for the VMs created for this backend (from the vms module)"
  type        = map(string)
}

variable "vm_names" {
  description = "Every VM name in config.json, so a typo in readers is caught (from the vms module)"
  type        = list(string)
}
