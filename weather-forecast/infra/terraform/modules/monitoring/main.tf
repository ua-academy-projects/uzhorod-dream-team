locals {
  prefix = var.config.project.prefix
  domain = var.config.app.public.domain
  alerts = var.config.monitoring.alerts

  vm_metrics = {
    cpu = {
      title    = "CPU utilization"
      scale    = 0.01
      group_by = "metric.label.instance_name"
      filter   = "metric.type=\"compute.googleapis.com/instance/cpu/utilization\" AND resource.type=\"gce_instance\""
    }
    memory = {
      title    = "Memory used"
      scale    = 1
      group_by = "metadata.system_labels.name"
      filter   = "metric.type=\"agent.googleapis.com/memory/percent_used\" AND resource.type=\"gce_instance\" AND metric.label.state=\"used\""
    }
    disk = {
      title    = "Root disk used"
      scale    = 1
      group_by = "metadata.system_labels.name"
      filter   = "metric.type=\"agent.googleapis.com/disk/percent_used\" AND resource.type=\"gce_instance\" AND metric.label.state=\"used\" AND metric.label.device=\"/dev/sda1\""
    }
  }

  responses_filter = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.nginx_responses.name}\" AND resource.type=\"gce_instance\""
  errors_filter    = "${local.responses_filter} AND metric.label.status_class=\"5\""
  uptime_filter    = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\" AND resource.label.host=\"${local.domain}\""

  vm_metric_alerts   = { for name, alert in local.alerts : name => alert if alert.type == "vm_metric" }
  error_share_alerts = { for name, alert in local.alerts : name => alert if alert.type == "error_share" }
  uptime_alerts      = { for name, alert in local.alerts : name => alert if alert.type == "uptime" }
}

data "google_client_config" "current" {}

resource "google_monitoring_notification_channel" "email" {
  display_name = "${local.prefix} email"
  type         = "email"

  labels = {
    email_address = var.alert_email
  }
}

resource "google_logging_metric" "nginx_responses" {
  name   = "${local.prefix}-nginx-responses"
  filter = "resource.type=\"gce_instance\" AND log_id(\"nginx_access\") AND httpRequest.status>0"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"

    labels {
      key        = "status_class"
      value_type = "STRING"
    }
  }

  label_extractors = {
    status_class = "REGEXP_EXTRACT(httpRequest.status, \"^(\\\\d)\")"
  }
}

resource "google_monitoring_uptime_check_config" "site" {
  for_each = var.config.monitoring.uptime_checks

  display_name = "${local.domain}${each.value}"
  timeout      = "10s"
  period       = "60s"

  http_check {
    path         = each.value
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = data.google_client_config.current.project
      host       = local.domain
    }
  }
}

resource "google_monitoring_alert_policy" "vm_metric" {
  for_each = local.vm_metric_alerts

  display_name          = "${local.vm_metrics[each.value.metric].title} above ${each.value.above}%"
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.id]

  documentation {
    content   = "${local.vm_metrics[each.value.metric].title} of a VM averaged over 5 minutes is above ${each.value.above}%."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "${local.vm_metrics[each.value.metric].title} above ${each.value.above}%"

    condition_threshold {
      filter          = local.vm_metrics[each.value.metric].filter
      comparison      = "COMPARISON_GT"
      threshold_value = each.value.above * local.vm_metrics[each.value.metric].scale
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }
}

resource "google_monitoring_alert_policy" "error_share" {
  for_each = local.error_share_alerts

  display_name          = "nginx 5xx above ${each.value.above}% of requests"
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.id]

  documentation {
    content   = "More than ${each.value.above}% of the requests to nginx over 5 minutes ended with a 5xx status."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "nginx 5xx above ${each.value.above}% of requests"

    condition_threshold {
      filter             = local.errors_filter
      denominator_filter = local.responses_filter
      comparison         = "COMPARISON_GT"
      threshold_value    = each.value.above / 100
      duration           = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
      }

      denominator_aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }
}

resource "google_monitoring_alert_policy" "uptime" {
  for_each = local.uptime_alerts

  display_name          = "${local.domain} is down"
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.id]

  documentation {
    content   = "Fewer than half of the uptime checks of ${local.domain} passed over 5 minutes."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "${local.domain} is down"

    condition_threshold {
      filter          = local.uptime_filter
      comparison      = "COMPARISON_LT"
      threshold_value = 0.5
      duration        = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_FRACTION_TRUE"
        cross_series_reducer = "REDUCE_MEAN"
        group_by_fields      = ["metric.label.check_id"]
      }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  depends_on = [google_monitoring_uptime_check_config.site]
}
