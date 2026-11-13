variable "config" {
  type = object({
    project = object({
      name_prefix = string
      region      = string
      zone        = string
    })
    cloudsql = object({
      tier                = string
      version             = string
      edition             = string
      disk_gb             = number
      deletion_protection = bool
    })
    postgres = object({
      database_name = string
    })
  })

  validation {
    condition     = !can(regex("^db-(f1|g1)-", var.config.cloudsql.tier)) || var.config.cloudsql.edition == "ENTERPRISE"
    error_message = "cloudsql: shared-core tiers (db-f1-*, db-g1-*) need edition ENTERPRISE."
  }
}

variable "network_id" {
  type = string
}

variable "iam_users" {
  type = map(string)
}
