variable "config" {
  description = "VM defaults and per-instance overrides"
  type = object({
    application = object({
      repo_url    = string
      repo_branch = string
    })
    defaults = object({
      machine_type = string
      boot_disk = object({
        image   = string
        size_gb = number
        type    = string
      })
      public_ip              = optional(bool, false)
      attach_service_account = optional(bool, true)
    })
    instances = map(object({
      name                   = string
      machine_type           = optional(string)
      network_ip             = optional(string)
      tags                   = optional(list(string), [])
      public_ip              = optional(bool)
      static_public_ip       = optional(bool, false)
      attach_service_account = optional(bool)
      boot_disk = optional(object({
        image   = optional(string)
        size_gb = optional(number)
        type    = optional(string)
      }), {})
      startup = optional(object({
        type         = string
        service_role = optional(string)
        ssh_port     = optional(number, 22)
        ip_https     = optional(bool, false)
      }), { type = "none" })
    }))
  })

}

variable "project_id" {
  type = string
}
variable "zone" {
  type = string
}
variable "subnet_id" {
  type = string
}
variable "service_account_email" {
  type = string
}

variable "region" {
  description = "Region for reserved public IP addresses"
  type        = string
}

variable "env_secret_id" {
  description = "Secret Manager secret containing the application environment"
  type        = string
}
