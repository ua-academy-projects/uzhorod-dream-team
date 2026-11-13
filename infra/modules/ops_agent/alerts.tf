# Alerts on what nginx returns (log "nginx_access", see the nginx policy in main.tf) and an external uptime check.
# Thresholds, severity and the recipient come from config.json "monitoring".

locals {
  # monitoring.nginx.rules key -> condition on the status code of the access log entry
  nginx_status = {
    "5xx" = ">=500"
    "404" = "=404"
    "429" = "=429"
  }
  nginx_descriptions = {
    "5xx" = "nginx answers with 5xx (502/504 mean the fetcher is down or too slow)"
    "404" = "many 404 answers: broken links or scanners probing the public address"
    "429" = "nginx rate limit (limit_req) is hit: abuse, or the limit is too strict"
  }
  window = "${var.monitoring.nginx.window_seconds}s"
}

resource "google_monitoring_notification_channel" "email" {
  project      = var.project_id
  display_name = "ops email"
  type         = "email"
  labels = {
    email_address = var.monitoring.email
  }
}

# --- counters made from the access log ---------------------------------------------------------------------------
resource "google_logging_metric" "nginx" {
  for_each    = var.monitoring.nginx.rules
  project     = var.project_id
  name        = "nginx_${each.key}"
  description = "nginx access log entries with status ${local.nginx_status[each.key]}"
  filter      = "resource.type=\"gce_instance\" AND log_id(\"nginx_access\") AND httpRequest.status${local.nginx_status[each.key]}"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_monitoring_alert_policy" "nginx" {
  for_each     = var.monitoring.nginx.rules
  project      = var.project_id
  display_name = "nginx ${each.key}: more than ${each.value.threshold} per ${var.monitoring.nginx.window_seconds}s"
  combiner     = "OR"
  severity     = each.value.severity

  conditions {
    display_name = "nginx ${each.key}"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.nginx[each.key].name}\" AND resource.type=\"gce_instance\""
      comparison      = "COMPARISON_GT"
      threshold_value = each.value.threshold
      duration        = "0s"

      aggregations {
        alignment_period     = local.window
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
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "${local.nginx_descriptions[each.key]}. Look at the log `nginx_access` on the frontend (Logs Explorer: `log_id(\"nginx_access\") AND httpRequest.status${local.nginx_status[each.key]}`)."
  }
}

# --- is the site up at all ---------------------------------------------------------------------------------------
# Logs say nothing when nginx or the VM is down, so this check comes from outside, from several Google regions.
resource "google_monitoring_uptime_check_config" "frontend" {
  project      = var.project_id
  display_name = "frontend ${var.monitoring.uptime.path}"
  timeout      = "10s"
  period       = "${var.monitoring.uptime.period_seconds}s"

  http_check {
    path         = var.monitoring.uptime.path
    port         = 443
    use_ssl      = true
    validate_ssl = var.monitoring.uptime.validate_ssl
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = var.domain
    }
  }
}

resource "google_monitoring_alert_policy" "uptime" {
  project      = var.project_id
  display_name = "frontend is down (${var.monitoring.uptime.path})"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "uptime check fails"

    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.label.check_id=\"${google_monitoring_uptime_check_config.frontend.uptime_check_id}\" AND resource.type=\"uptime_url\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1 # fails from more than one location
      duration        = "60s"

      aggregations {
        alignment_period     = "1200s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.*"]
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
    content   = "https://${var.domain}${var.monitoring.uptime.path} does not answer from several locations: nginx or the VM is down, or the certificate is invalid (validate_ssl=${var.monitoring.uptime.validate_ssl})."
  }
}
