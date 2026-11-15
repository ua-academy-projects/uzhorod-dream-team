resource "google_monitoring_notification_channel" "email" {
  count        = local.enabled && local.config.notification.enabled ? 1 : 0
  project      = var.config.project_id
  display_name = local.config.notification.display_name
  type         = "email"
  labels       = { email_address = local.config.notification.email }
  depends_on   = [google_project_service.monitoring]
}

resource "google_monitoring_alert_policy" "utilization" {
  for_each              = { for key, metric in local.metrics : key => metric if local.config.utilization_alert.enabled && metric.alert_enabled }
  project               = var.config.project_id
  display_name          = each.value.alert_name
  combiner              = "OR"
  notification_channels = google_monitoring_notification_channel.email[*].name
  conditions {
    display_name = local.config.utilization_alert.condition_name
    condition_threshold {
      filter          = each.value.filter
      comparison      = local.config.utilization_alert.comparison
      threshold_value = each.value.threshold * each.value.scale
      duration        = local.config.utilization_alert.duration
      aggregations {
        alignment_period   = local.config.utilization_alert.alignment_period
        per_series_aligner = local.config.utilization_alert.aligner
      }
      trigger { count = local.config.utilization_alert.trigger_count }
    }
  }
  alert_strategy { auto_close = local.config.utilization_alert.auto_close }
  documentation {
    mime_type = "text/markdown"
    content   = local.config.utilization_alert.documentation
  }
}

resource "google_monitoring_alert_policy" "uptime" {
  count                 = local.enabled && local.config.uptime_check.enabled && local.config.uptime_alert.enabled ? 1 : 0
  project               = var.config.project_id
  display_name          = local.config.uptime_alert.display_name
  combiner              = "OR"
  notification_channels = google_monitoring_notification_channel.email[*].name
  conditions {
    display_name = local.config.uptime_alert.condition_name
    condition_threshold {
      filter          = "resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.labels.check_id = \"${google_monitoring_uptime_check_config.ui[0].uptime_check_id}\""
      comparison      = local.config.uptime_alert.comparison
      threshold_value = local.config.uptime_alert.threshold
      duration        = local.config.uptime_alert.duration
      aggregations {
        alignment_period     = local.config.uptime_alert.alignment_period
        per_series_aligner   = local.config.uptime_alert.aligner
        cross_series_reducer = local.config.uptime_alert.reducer
        group_by_fields      = local.config.uptime_alert.group_by_fields
      }
      trigger { count = local.config.uptime_alert.trigger_count }
    }
  }
  alert_strategy { auto_close = local.config.uptime_alert.auto_close }
  documentation {
    mime_type = "text/markdown"
    content   = local.config.uptime_alert.documentation
  }
}
