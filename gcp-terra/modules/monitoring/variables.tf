variable "config" {
  description = "Shared configuration; this module selects its own settings."
  type = object({
    project_id = string
    monitoring = optional(object({
      enabled            = optional(bool, false)
      notification_email = optional(string)
      cpu_threshold      = optional(number, 0.8)
      disk_threshold     = optional(number, 0.8)
      memory_threshold   = optional(number, 0.9)
      duration           = optional(string, "300s")
    }))
    cloud_sql = optional(object({ managed = optional(bool, false), instance_name = optional(string) }))
  })
  validation {
    condition     = !try(var.config.monitoring.enabled, false) || try(length(var.config.monitoring.notification_email) > 0, false)
    error_message = "Enabled monitoring requires a notification email."
  }
}
variable "instance_ids" { type = map(string) }
variable "service_account_emails" { type = map(string) }
variable "public_ips" { type = map(string) }
