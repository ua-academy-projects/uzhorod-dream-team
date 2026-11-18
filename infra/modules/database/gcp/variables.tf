variable "config" {
  description = "infra/config.json as a whole; this module uses prefix, clouds.gcp.database.private_range, database.managed and app.db_name"
  type = object({
    prefix = string
    clouds = object({
      gcp = object({
        database = object({ private_range = string })
      })
    })
    database = object({
      managed = object({
        version             = string
        disk_gb             = number
        deletion_protection = bool
      })
    })
    app = object({ db_name = string })
  })
}

variable "network_id" {
  description = "Our VPC: the ONLY place the database can be reached from"
  type        = string
}

variable "region" {
  type = string
}

variable "zone" {
  type = string
}

variable "size" {
  description = "The Cloud SQL tier, e.g. db-f1-micro (modules/database turns config.json's word into it)"
  type        = string
}
