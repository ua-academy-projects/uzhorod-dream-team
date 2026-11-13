# Alerts defined entirely by config.json "monitoring.metric_alerts" and "monitoring.log_alerts" (the nginx alerts in alerts.tf have their own rules).
# Adding an alert means adding an entry to config.json, not new Terraform.

# --- a threshold on a metric ---------------------------------------------------------------------------------------
# No cross-series reducer: every VM (and every disk) is judged separately, so the incident names the guilty one.
resource "google_monitoring_alert_policy" "metric" {
  for_each     = var.monitoring.metric_alerts
  project      = var.project_id
  display_name = "${each.key}: ${each.value.description}"
  combiner     = "OR"
  severity     = each.value.severity

  conditions {
    display_name = each.key

    condition_threshold {
      filter = join(" AND ", compact([
        "metric.type=\"${each.value.metric}\"",
        "resource.type=\"${each.value.resource_type}\"",
        each.value.filter,
      ]))
      comparison      = each.value.comparison
      threshold_value = each.value.threshold
      duration        = "${each.value.duration_seconds}s"

      aggregations {
        alignment_period   = "${each.value.window_seconds}s"
        per_series_aligner = each.value.aligner
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "${each.value.description}. Metric `${each.value.metric}` (${each.value.comparison} ${each.value.threshold}, window ${each.value.window_seconds}s). The incident names the VM."
  }
}

# --- number of log lines that match a filter -----------------------------------------------------------------------
resource "google_logging_metric" "log" {
  for_each    = var.monitoring.log_alerts
  project     = var.project_id
  name        = "alert_${each.key}"
  description = each.value.description
  filter      = "resource.type=\"gce_instance\" AND ${each.value.filter}"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_monitoring_alert_policy" "log" {
  for_each     = var.monitoring.log_alerts
  project      = var.project_id
  display_name = "${each.key}: ${each.value.description}"
  combiner     = "OR"
  severity     = each.value.severity

  conditions {
    display_name = each.key

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.log[each.key].name}\" AND resource.type=\"gce_instance\""
      comparison      = "COMPARISON_GT"
      threshold_value = each.value.threshold
      duration        = "0s"

      aggregations {
        alignment_period     = "${each.value.window_seconds}s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]

  alert_strategy {
    auto_close = "86400s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "${each.value.description}. Logs Explorer: `${each.value.filter}`."
  }
}
