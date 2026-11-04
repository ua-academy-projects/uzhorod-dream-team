variable "cfg" {
  type = object({
    google      = object({ project_id = string, region = string, zone = string })
    application = object({ database_name = string, postgres_only = bool })
    cloud_sql = optional(object({
      name         = optional(string, "kyiv-air-postgres")
      tier         = optional(string, "db-f1-micro")
      disk_size_gb = optional(number, 10)
    }), {})
  })
}

variable "network" {
  type = object({ network_id = string, subnetwork_id = string })
}

variable "secrets" {
  type = object({
    secrets = map(object({
      secret_id = string
      version   = string
    }))
  })
}

variable "revisions" {
  type    = map(number)
  default = {}
}

variable "service_accounts" {
  type        = map(object({ email = string }))
  description = "VM service accounts granted Cloud SQL client access"
  default     = {}
}
