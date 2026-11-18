locals {
  alerts = var.config.monitoring.alerts
  window = "300s"

  labels = {
    app        = var.config.prefix
    managed-by = "terraform"
  }
}

resource "google_monitoring_notification_channel" "email" {
  display_name = "${var.config.prefix}: e-mail"
  type         = "email"
  user_labels  = local.labels

  labels = {
    email_address = var.config.monitoring.email
  }
}


resource "google_monitoring_alert_policy" "disk" {
  display_name          = "${var.config.prefix} [${local.alerts.disk_percent.severity}]: disk over ${local.alerts.disk_percent.threshold}%"
  severity              = local.alerts.disk_percent.severity
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.id]
  user_labels           = local.labels

  conditions {
    display_name = "/dev/sda1 used > ${local.alerts.disk_percent.threshold}%"
    condition_threshold {
      filter          = local.metric_filter.disk
      comparison      = "COMPARISON_GT"
      threshold_value = local.alerts.disk_percent.threshold
      duration        = "${local.alerts.disk_percent.minutes * 60}s"
      aggregations {
        alignment_period   = local.window
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "The root disk of a VM is filling up. On the VM: `df -h /`, then `docker system df` and `docker system prune` for old images."
  }
}

resource "google_monitoring_alert_policy" "error_rate" {
  display_name          = "${var.config.prefix} [${local.alerts.error_rate_percent.severity}]: error rate over ${local.alerts.error_rate_percent.threshold}%"
  severity              = local.alerts.error_rate_percent.severity
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.id]
  user_labels           = local.labels

  conditions {
    display_name = "5xx > ${local.alerts.error_rate_percent.threshold}% of requests"
    condition_threshold {
      filter          = local.log_filter.request_errors
      comparison      = "COMPARISON_GT"
      threshold_value = local.alerts.error_rate_percent.threshold / 100
      duration        = "${local.alerts.error_rate_percent.minutes * 60}s"
      aggregations {
        alignment_period     = local.window
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_MEAN"
      }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "The site answers with 5xx. Usually history is down or cannot reach the database: `docker logs history` on the history VM, then the database."
  }
}

resource "google_monitoring_alert_policy" "latency" {
  display_name          = "${var.config.prefix} [${local.alerts.latency_p95_seconds.severity}]: p95 latency over ${local.alerts.latency_p95_seconds.threshold}s"
  severity              = local.alerts.latency_p95_seconds.severity
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.id]
  user_labels           = local.labels

  conditions {
    display_name = "p95 of request time > ${local.alerts.latency_p95_seconds.threshold}s"
    condition_threshold {
      filter          = local.log_filter.latency
      comparison      = "COMPARISON_GT"
      threshold_value = local.alerts.latency_p95_seconds.threshold
      duration        = "${local.alerts.latency_p95_seconds.minutes * 60}s"
      aggregations {
        alignment_period   = local.window
        per_series_aligner = "ALIGN_PERCENTILE_95"
      }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "The site is slow. Look at CPU and memory of the history VM and at the database (Cloud SQL CPU, connections)."
  }
}

resource "google_monitoring_alert_policy" "no_snapshots" {
  display_name          = "${var.config.prefix} [${local.alerts.no_snapshots.severity}]: no snapshots for ${local.alerts.no_snapshots.minutes} min"
  severity              = local.alerts.no_snapshots.severity
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.id]
  user_labels           = local.labels

  conditions {
    display_name = "history stored no snapshot"
    condition_absent {
      filter   = local.log_filter.snapshots
      duration = "${local.alerts.no_snapshots.minutes * 60}s"
      aggregations {
        alignment_period   = local.window
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "history stores no new data: the site shows old numbers. `docker logs history` on the history VM (\"poll failed\" says why), then fetcher."
  }
}
