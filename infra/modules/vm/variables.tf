variable "config" {
  type = object({
    project = object({
      name_prefix = string
      region      = string
      zone        = string
    })
    vms = map(object({
      bastion      = optional(bool, false)
      machine_type = optional(string)
      image        = optional(string)
      disk_type    = optional(string)
      disk_gb      = optional(number)
    }))
    vm_defaults = object({
      machine_type = string
      image        = string
      disk_type    = string
      disk_gb      = number
    })
  })
}

variable "key" {
  type = string

  validation {
    condition     = contains(keys(var.config.vms), var.key)
    error_message = "key must be a key of vms."
  }
}

variable "subnetwork_id" {
  type = string
}

variable "ip" {
  type = string
}

variable "user_data" {
  type = string
}

variable "service_account" {
  type    = string
  default = null
}
