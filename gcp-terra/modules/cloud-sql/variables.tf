variable "config" {
  description = "Shared configuration; this module selects its own settings."
  type = object({
    project_id = string
    database   = object({ provider = string, name = string })
    cloud_sql = optional(object({
      managed = optional(bool, false)

      instance_name               = optional(string)
      database_version            = optional(string)
      region                      = optional(string)
      zone                        = optional(string)
      tier                        = optional(string)
      edition                     = optional(string)
      public_ip                   = optional(bool)
      deletion_protection         = optional(bool)
      disk_size_gb                = optional(number)
      disk_type                   = optional(string)
      disk_autoresize             = optional(bool)
      availability_type           = optional(string)
      data_cache_enabled          = optional(bool)
      enable_dataplex_integration = optional(bool)
      database_flags              = optional(map(string))
      backup = optional(object({
        enabled                        = bool
        point_in_time_recovery_enabled = bool
        start_time                     = string
        transaction_log_retention_days = number
        retained_backups               = number
      }))
      private_service_access = optional(object({
        ranges         = map(object({ address = string, prefix_length = number }))
        peering_ranges = list(string)
      }))
    }))
  })
  validation {
    condition = !try(var.config.cloud_sql.managed, false) || try(
      alltrue([for value in var.config.cloud_sql : value != null]), false
    )
    error_message = "Managed Cloud SQL requires complete instance, backup and private service access settings."
  }
  validation {
    condition = !try(var.config.cloud_sql.managed, false) || try(
      startswith(var.config.cloud_sql.zone, "${var.config.cloud_sql.region}-") &&
      contains(["ZONAL", "REGIONAL"], var.config.cloud_sql.availability_type), false
    )
    error_message = "Managed Cloud SQL requires a zone in its region and ZONAL or REGIONAL availability."
  }
  validation {
    condition = !try(var.config.cloud_sql.managed, false) || try(
      !var.config.cloud_sql.backup.point_in_time_recovery_enabled || var.config.cloud_sql.backup.enabled, false
    )
    error_message = "Cloud SQL point-in-time recovery requires backups to be enabled."
  }
  validation {
    condition = !try(var.config.cloud_sql.managed, false) || try(
      length(var.config.cloud_sql.private_service_access.peering_ranges) > 0 &&
      alltrue([for name in var.config.cloud_sql.private_service_access.peering_ranges : contains(keys(var.config.cloud_sql.private_service_access.ranges), name)]), false
    )
    error_message = "Cloud SQL peering_ranges must reference at least one declared private service access range."
  }
}
variable "network_id" { type = string }
variable "service_account_emails" { type = map(string) }
