variable "project_id" { type = string }
variable "config" {
  type = object({
    notification_email = string
    cpu_threshold      = number
    disk_threshold     = number
    memory_threshold   = number
    duration           = string
  })
}
variable "instance_ids" { type = map(string) }
variable "service_account_emails" { type = map(string) }
variable "sql_instance_name" { type = string }
variable "ui_host" { type = string }
