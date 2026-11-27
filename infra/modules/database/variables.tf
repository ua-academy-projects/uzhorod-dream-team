variable "config" {
  description = "infra/config.json as a whole; this module uses prefix, default_cloud, region, zone, clouds.<cloud> (location, network, database), vms.instances (ip_index, cloud), database and app.db_name"
  type = object({
    prefix        = string
    default_cloud = string
    region        = string
    zone          = string
    clouds        = any
    vms = object({
      instances = map(object({
        ip_index = number
        cloud    = optional(string)
      }))
    })
    database = object({
      type = string
      vm   = string
      managed = optional(object({
        version             = string
        size                = string
        disk_gb             = number
        deletion_protection = optional(bool, true)
      }))
    })
    app = object({ db_name = string })
  })

  validation {
    condition     = contains(["managed", "vm"], var.config.database.type)
    error_message = "config.json: database.type must be \"managed\" or \"vm\"."
  }

  validation {
    condition     = var.config.database.type != "managed" || var.config.database.managed != null
    error_message = "config.json: database.type is \"managed\", so database.managed is needed."
  }

  validation {
    condition     = var.config.database.type != "managed" || can(var.config.clouds[var.config.default_cloud].database.sizes[var.config.database.managed.size])
    error_message = "config.json: database.managed.size is not in clouds.${var.config.default_cloud}.database.sizes."
  }

  validation {
    condition     = var.config.database.type != "managed" || var.config.default_cloud != "aws" || try(var.config.database.managed.disk_gb >= 20, false)
    error_message = "config.json: database.managed.disk_gb must be at least 20 in AWS (the RDS minimum)."
  }
}

variable "networks" {
  description = "cloud => { network_id, ... }: the VPC is the only place the managed database can be reached from (modules/network)"
  type        = any
}
