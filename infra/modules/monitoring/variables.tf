variable "config" {
  description = "infra/config.json as a whole; this module uses prefix, tls.domain, database.type and monitoring"
  type = object({
    prefix   = string
    tls      = object({ domain = string })
    database = object({ type = string })
    monitoring = object({
      email             = string
      disk_used_percent = number
      silence_minutes   = number
      poll_failures     = number
      uptime_path       = string
    })
  })
}

variable "project_id" {
  type = string
}