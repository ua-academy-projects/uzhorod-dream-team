variable "cfg" {
  type = object({
    google = object({
      project_id = string
    })
    monitoring = object({
      dashboard_name = optional(string, "Kyiv Air (Terraform)")
      widgets = list(object({
        id            = string
        title         = string
        type          = string
        metric_type   = string
        resource_type = optional(string, "gce_instance")
        filters       = optional(list(string), [])
        aligner       = optional(string, "ALIGN_MEAN")
        reducer       = optional(string, "REDUCE_NONE")
        group_by      = optional(list(string), [])
        period_s      = optional(number, 60)
        plot_type     = optional(string, "LINE")
        legend        = optional(string)
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
        documentation = optional(string)
      })), {})
    })
  })
}

variable "notification_channel_ids" {
  type        = list(string)
  description = "Existing notification channel IDs (projects/<project>/notificationChannels/<number>) that alerts notify. Leave empty to create policies without a channel."
  default     = []
}
