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
}
variable "network_id" { type = string }
variable "service_account_emails" { type = map(string) }
