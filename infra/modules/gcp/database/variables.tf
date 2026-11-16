variable "config" {
  description = "infra/config.json as a whole; this module uses prefix, clouds.gcp (region, zones, database_private_range, database_sizes), database.managed and app.db_name"
  type = object({
    prefix = string
    clouds = object({
      gcp = object({
        region                 = string
        zones                  = list(string)
        database_private_range = string
        database_sizes         = map(string)
      })
    })
    database = object({
      managed = object({
        version             = string
        size                = string
        disk_gb             = number
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
