variable "project_id" {
  type        = string
  description = "Project whose VMs get the Ops Agent."
}

variable "zones" {
  type        = set(string)
  description = "Zones that contain the VMs. An OS policy assignment is zonal, so one is created per zone."
}

variable "nginx_zones" {
  type        = set(string)
  description = "Zones of the VMs labelled ops_agent=nginx. They get the Ops Agent nginx log configuration."
}

variable "domain" {
  type        = string
  description = "Public domain of the frontend, the host of the uptime check."
}

variable "monitoring" {
  description = "Alerting: recipient and thresholds (config.json \"monitoring\")."
  type = object({
    email = string
    nginx = object({
      window_seconds = number
      rules = map(object({
        threshold = number
        severity  = string
      }))
    })
    uptime = object({
      path           = string
      period_seconds = number
      validate_ssl   = bool
    })
    # Threshold alerts on a metric, one alert policy per entry (alerts_infra.tf). Every series is judged on its own, so a VM or a disk each get their own incident.
    metric_alerts = map(object({
      description      = string
      resource_type    = string
      metric           = string
      filter           = optional(string, "")
      comparison       = string
      threshold        = number
      aligner          = string
      window_seconds   = number
      duration_seconds = optional(number, 0)
      severity         = string
    }))
    # Alerts on how many log lines match a filter in a window: a log-based counter plus an alert policy per entry.
    log_alerts = map(object({
      description    = string
      filter         = string
      threshold      = number
      window_seconds = number
      severity       = string
    }))
  })

  validation {
    condition     = alltrue([for k in keys(var.monitoring.nginx.rules) : contains(["5xx", "404", "429"], k)])
    error_message = "monitoring.nginx.rules may only contain the keys 5xx, 404 and 429."
  }
  validation {
    condition     = alltrue([for r in values(var.monitoring.nginx.rules) : contains(["CRITICAL", "ERROR", "WARNING"], r.severity)])
    error_message = "monitoring.nginx.rules severity must be CRITICAL, ERROR or WARNING."
  }
  validation {
    condition = alltrue([
      for a in concat(values(var.monitoring.metric_alerts), values(var.monitoring.log_alerts)) : contains(["CRITICAL", "ERROR", "WARNING"], a.severity)
    ])
    error_message = "monitoring.metric_alerts and monitoring.log_alerts severity must be CRITICAL, ERROR or WARNING."
  }
  validation {
    condition     = alltrue([for a in values(var.monitoring.metric_alerts) : contains(["COMPARISON_GT", "COMPARISON_LT"], a.comparison)])
    error_message = "monitoring.metric_alerts comparison must be COMPARISON_GT or COMPARISON_LT."
  }
}
