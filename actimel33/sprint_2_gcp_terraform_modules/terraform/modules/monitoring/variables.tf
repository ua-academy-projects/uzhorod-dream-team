variable "config" {
  description = "config.json; this module reads project, app (database), load_balancer (domain) and monitoring"
  type = object({
    project = object({
      id = string
    })
    app = object({
      database = string
    })
    load_balancer = object({
      domain = string
    })
    monitoring = object({
      notification_email       = string
      uptime_check_path        = string
      uptime_check_content     = string
      uptime_check_regions     = list(string)
      cpu_threshold            = number
      memory_threshold_percent = number
      lb_5xx_ratio_threshold   = number
    })
  })

  validation {
    condition     = var.config.monitoring.cpu_threshold > 0 && var.config.monitoring.cpu_threshold <= 1
    error_message = "monitoring.cpu_threshold is a share of the CPU, from 0 to 1."
  }

  validation {
    condition     = var.config.monitoring.memory_threshold_percent > 0 && var.config.monitoring.memory_threshold_percent <= 100
    error_message = "monitoring.memory_threshold_percent is a percent, from 0 to 100."
  }

  validation {
    condition     = var.config.monitoring.lb_5xx_ratio_threshold > 0 && var.config.monitoring.lb_5xx_ratio_threshold <= 1
    error_message = "monitoring.lb_5xx_ratio_threshold is a share of the requests, from 0 to 1."
  }
}

variable "https_rule" {
  description = "Name of the HTTPS forwarding rule of the load balancer, from the load_balancer module"
  type        = string
}
