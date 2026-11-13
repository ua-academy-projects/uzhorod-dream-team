variable "config" {
  type = object({
    vms = map(object({
      bastion = optional(bool, false)
    }))
    access = object({
      admin_cidrs    = list(string)
      ssh_public_key = string
      ssh_port       = optional(number, 22)
    })
  })

  validation {
    condition     = length([for v in values(var.config.vms) : v if v.bastion]) == 1
    error_message = "Exactly one VM in vms must have bastion: true."
  }
}

variable "ips" {
  type = map(string)
}
