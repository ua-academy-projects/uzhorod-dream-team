variable "google" {
  type = object({
    project_id = string
    region     = string
    zone       = string
    service_account = optional(object({
      email = string
    }), null)
  })
  description = "Google related values"
}

variable "name_prefix" {
  type        = string
  description = "VM name prefix"
  default     = "kyiv-air"
}

variable "machine" {
  type = object({
    name         = string
    machine_type = optional(string, "e2-micro")
    boot_disk = object({
      image   = optional(string, "ubuntu-os-cloud/ubuntu-minimal-2604-lts-amd64")
      size_gb = number
      type    = optional(string, "pd-balanced")
    })
    data_disk = optional(object({
      size_gb     = number
      type        = string
      device_name = string
    }))
    scripts    = set(string)
    entrypoint = string
    env        = optional(map(string), {})
    secrets    = optional(set(string), [])
  })
}

variable "network" {
  type = object({
    subnetwork_id = string
    private_ip    = string
    tags          = set(string)
    public_ips    = optional(map(string), null)
    public_tier   = optional(string, "STANDARD")
    firewall_rules = map(object({
      ports = set(number)
    }))
  })
}

variable "application" {
  type = object({
    image_version = string
    postgres_only = bool
    database_name = string
    ready_timeout = number
  })
}

variable "images" {
  type = map(string)
}

variable "domain" {
  type = string
}

variable "registry_url" {
  type = string
}

variable "secrets" {
  type = object({
    versions = optional(map(string), {})
    secrets = map(object({
      secret_id = string
      version   = string
    }))
  })
}

variable "vms" {
  type = map(object({ private_ip = string }))
}

