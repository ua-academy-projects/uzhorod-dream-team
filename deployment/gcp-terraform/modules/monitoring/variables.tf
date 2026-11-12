variable "cfg" {
  type = object({
    google = object({
      project_id = string
    })
    cloudflare = object({
      domain = string
    })
    monitoring = object({
      dashboard_name = optional(string, "Kyiv Air (Terraform)")
      uptime_check = optional(object({
        display_name = optional(string, "UI uptime check")
        host         = optional(string)
        path         = optional(string, "/")
        period_s     = optional(number, 60)
        timeout_s    = optional(number, 10)
      }))
      log_metrics = optional(map(object({
        description     = optional(string)
        filter          = list(string)
        label_name      = string
        label_extractor = string
      })), {})
      widgets = list(object({
        id            = string
        title         = string
        type          = string
        enabled       = optional(bool, true)
        metric_type   = string
        resource_type = optional(string, "gce_instance")
        filters       = optional(list(string), [])
        aligner       = optional(string, "ALIGN_MEAN")
        reducer       = optional(string, "REDUCE_NONE")
        group_by      = optional(list(string), [])
        period_s      = optional(number, 60)
        plot_type     = optional(string, "LINE")
        legend        = optional(string)
        unit          = optional(string)
        spark         = optional(bool, false)
        top_series    = optional(number)
        layout = optional(object({
          x      = optional(number, 0)
          y      = optional(number, 0)
          width  = optional(number, 6)
          height = optional(number, 4)
        }), {})
        thresholds = optional(list(object({
          value     = number
          color     = optional(string)
          direction = optional(string, "ABOVE")
          label     = optional(string)
        })), [])
      }))
      alerts = optional(map(object({
        widget        = string
        severity      = optional(string)
        display_name  = optional(string)
        comparison    = optional(string, "COMPARISON_GT")
        threshold     = number
        duration_s    = optional(number, 300)
        no_data_ok    = optional(bool, false)
        check         = optional(bool, false)
        documentation = optional(string)
        aggregation = optional(object({
          aligner  = optional(string)
          reducer  = optional(string)
          group_by = optional(list(string))
          period_s = optional(number)
        }))
      })), {})
    })
  })
}

variable "alert_email" {
  type        = string
  description = "Email address that receives alert notifications. When null, no notification channel is created and alerts only open incidents."
  sensitive   = true
  default     = null
}
