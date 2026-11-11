variable "project_id" { type = string }
variable "network_id" { type = string }
variable "database_name" { type = string }
variable "service_account_emails" { type = map(string) }
variable "client_services" { type = set(string) }
variable "config" {
  type = object({
    instance_name               = string
    database_version            = string
    region                      = string
    zone                        = string
    tier                        = string
    edition                     = string
    public_ip                   = bool
    deletion_protection         = bool
    disk_size_gb                = number
    disk_type                   = string
    disk_autoresize             = bool
    availability_type           = string
    data_cache_enabled          = bool
    enable_dataplex_integration = bool
    database_flags              = map(string)
    backup = object({
      enabled                        = bool
      point_in_time_recovery_enabled = bool
      start_time                     = string
      transaction_log_retention_days = number
      retained_backups               = number
    })
    private_service_access = object({
      ranges         = map(object({ address = string, prefix_length = number }))
      peering_ranges = list(string)
    })
  })
}
