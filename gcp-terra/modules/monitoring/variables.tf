variable "config" {
  description = "Shared project and Cloud SQL resource settings."
  type = object({
    project_id = string
    compute    = object({ instances = map(object({ name = string })) })
    cloud_sql  = optional(object({ managed = optional(bool, false), instance_name = optional(string) }))
  })
}
variable "instance_ids" { type = map(string) }
variable "service_account_emails" { type = map(string) }
variable "public_ips" { type = map(string) }
variable "monitoring" {
  description = "All monitoring settings from the root monitoring.json."
  type = object({
    enabled = bool
    notification = object({
      enabled      = bool
      display_name = string
      email        = string
    })
    agent = object({
      enabled    = bool
      write_logs = bool
      config     = any
    })
    uptime_check = object({
      enabled      = bool
      display_name = string
      timeout      = string
      period       = string
      regions      = list(string)
      path         = string
      port         = number
      use_ssl      = bool
      validate_ssl = bool
      status_class = string
    })
    metrics = map(object({
      enabled       = bool
      title         = string
      scope         = string
      filter        = string
      threshold     = number
      scale         = number
      alert_enabled = bool
      alert_name    = string
    }))
    utilization_alert = object({
      enabled          = bool
      condition_name   = string
      comparison       = string
      duration         = string
      alignment_period = string
      aligner          = string
      trigger_count    = number
      auto_close       = string
      documentation    = string
    })
    uptime_alert = object({
      enabled          = bool
      display_name     = string
      condition_name   = string
      comparison       = string
      threshold        = number
      duration         = string
      alignment_period = string
      aligner          = string
      reducer          = string
      group_by_fields  = list(string)
      trigger_count    = number
      auto_close       = string
      documentation    = string
    })
    dashboard = object({
      display_name     = string
      columns          = number
      alignment_period = string
      widgets = list(object({
        type                = string
        x                   = number
        y                   = number
        width               = number
        height              = number
        service             = optional(string)
        filter              = optional(string)
        reducer             = optional(string, "REDUCE_NONE")
        group_by_fields     = optional(list(string), [])
        unit                = optional(string, "")
        upper_bound         = optional(number, 100)
        threshold           = optional(number)
        threshold_direction = optional(string, "ABOVE")
        show_threshold      = optional(bool, true)
        legend_template     = optional(string, "")
        metric              = string
        title               = string
        axis_label          = string
        aligner             = string
      }))
      enabled = bool
    })
  })
  validation {
    condition     = alltrue([for metric in values(var.monitoring.metrics) : contains(["vm", "agent", "sql"], metric.scope) && metric.threshold >= 0 && metric.threshold <= 1 && metric.scale > 0])
    error_message = "Metrics require a supported scope, threshold between 0 and 1, and positive scale."
  }
  validation {
    condition     = alltrue([for widget in var.monitoring.dashboard.widgets : contains(concat(keys(var.monitoring.metrics), ["uptime"]), widget.metric)])
    error_message = "Every dashboard widget must reference a configured metric."
  }
  validation {
    condition     = var.monitoring.dashboard.columns >= 1 && floor(var.monitoring.dashboard.columns) == var.monitoring.dashboard.columns && trimspace(var.monitoring.dashboard.display_name) != ""
    error_message = "Dashboard requires a nonempty name and positive integer columns."
  }
  validation {
    condition     = !var.monitoring.enabled || !var.monitoring.notification.enabled || can(regex("^[^ @]+@[^ @]+\\.[^ @]+$", var.monitoring.notification.email))
    error_message = "Enabled monitoring requires a notification email."
  }
  validation {
    condition     = alltrue([for period in [var.monitoring.dashboard.alignment_period, var.monitoring.utilization_alert.alignment_period, var.monitoring.uptime_alert.alignment_period] : can(regex("^[1-9][0-9]*s$", period)) && try(tonumber(trimsuffix(period, "s")) >= 60, false)])
    error_message = "Alignment periods must be integer seconds, at least 60s."
  }
  validation {
    condition     = alltrue([for alert in [var.monitoring.utilization_alert, var.monitoring.uptime_alert] : try(tonumber(trimsuffix(alert.duration, "s")) % 60 == 0, false) && can(regex("^[0-9]+s$", alert.duration)) && try(tonumber(trimsuffix(alert.auto_close, "s")) >= 1800, false) && alert.trigger_count >= 1 && floor(alert.trigger_count) == alert.trigger_count])
    error_message = "Alerts require duration in multiples of 60s, auto_close >= 1800s and a positive integer trigger_count."
  }
  validation {
    condition     = contains(["60s", "300s", "600s"], var.monitoring.uptime_check.period) && var.monitoring.uptime_check.port >= 1 && var.monitoring.uptime_check.port <= 65535 && floor(var.monitoring.uptime_check.port) == var.monitoring.uptime_check.port
    error_message = "Use a supported chart type, uptime period (60s/300s/600s), and integer port 1–65535."
  }
  validation {
    condition = var.monitoring.agent.write_logs || try(
      var.monitoring.agent.config.global.default_self_log_file_collection == false &&
      length(var.monitoring.agent.config.logging.service.pipelines.default_pipeline.receivers) == 0 &&
    alltrue([for pipeline in values(var.monitoring.agent.config.logging.service.pipelines) : length(pipeline.receivers) == 0]), false)
    error_message = "Log ingestion requires agent.write_logs=true; otherwise explicitly disable default/custom logging pipelines and self-log collection."
  }

  validation {
    condition     = alltrue([for widget in var.monitoring.dashboard.widgets : contains(["line", "bar", "donut", "pie", "scorecard"], widget.type) && widget.x >= 0 && widget.y >= 0 && widget.width > 0 && widget.height > 0 && widget.x + widget.width <= var.monitoring.dashboard.columns && alltrue([for value in [widget.x, widget.y, widget.width, widget.height] : floor(value) == value]) && (widget.service == null ? true : contains(keys(var.config.compute.instances), widget.service))])
    error_message = "Widgets require a supported type, valid VM service and integer coordinates/sizes inside the mosaic columns."
  }

}
