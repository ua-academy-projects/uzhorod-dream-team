variable "config" {
  description = "infra/config.json as a whole; this module uses prefix, location, database and app.db_name"
  type = object({
    prefix   = string
    location = object({ region = string, zone = string })
    database = object({
      cloudsql = object({
        version             = string
        tier                = string
        disk_size_gb        = number
        private_range       = string
        deletion_protection = optional(bool, true)
      })
    })
    app = object({
      db_name = string
    })
  })
}

variable "network_id" {
  description = "Our VPC: the ONLY place the database can be reached from"
  type        = string
}
