variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "subnet_ids" {
  type = map(string)
}

# instance name -> service account email (modules/iam)
variable "service_account_emails" {
  type = map(string)
}

variable "defaults" {
  type = object({
    image        = string
    machine_type = string
    disk_size_gb = number
    zone         = string
    subnet       = string
    external_ip  = bool
  })
}

variable "instances" {
  type = map(object({
    internal_ip         = string
    subnet              = optional(string)
    external_ip         = optional(bool)
    static_ip           = optional(bool, false)
    zone                = optional(string)
    machine_type        = optional(string)
    disk_size_gb        = optional(number)
    deletion_protection = optional(bool)
    labels              = optional(map(string), {})
  }))
}
