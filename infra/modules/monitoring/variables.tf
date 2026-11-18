variable "config" {
  description = "infra/config.json as a whole; this module uses prefix, default_cloud, tls.domain and monitoring"
  type = object({
    prefix        = string
    default_cloud = string
    tls           = object({ domain = string })

    monitoring = object({
      email = string

      alerts = object({
        disk_percent        = object({ severity = string, threshold = number, minutes = number })
        error_rate_percent  = object({ severity = string, threshold = number, minutes = number })
        latency_p95_seconds = object({ severity = string, threshold = number, minutes = number })
        no_snapshots        = object({ severity = string, minutes = number })
      })
    })
  })

  validation {
    condition     = var.config.tls.domain != ""
    error_message = "config.json: tls.domain is empty, and the uptime check needs the site's address."
  }

  validation {
    condition     = alltrue([for alert in values(var.config.monitoring.alerts) : contains(["CRITICAL", "ERROR", "WARNING"], alert.severity)])
    error_message = "config.json: monitoring.alerts: severity is one of CRITICAL, ERROR, WARNING."
  }
}
