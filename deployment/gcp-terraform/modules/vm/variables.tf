variable "project_id" {
  type = string
}

variable "name" {
  type = string
}

variable "zone" {
  type = string
}

variable "config" {
  type = object({
    machine_type = string
    boot_disk = object({
      image   = string
      size_gb = number
      type    = string
    })
    data_disk = optional(object({
      size_gb     = number
      type        = string
      device_name = string
    }))
  })
}

variable "network" {
  type = object({
    subnetwork_id = string
    private_ip    = string
    tags          = set(string)
    public_access = optional(object({
      ip   = string
      tier = string
    }))
  })
}

variable "service_account" {
  type = object({
    email = string
  })
  default = null
}

variable "startup_script" {
  type = string
}
