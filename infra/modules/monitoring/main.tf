locals {
  prefix   = var.config.prefix
  m        = var.config.monitoring
  domain   = var.config.tls.domain
  labels   = { app = var.config.prefix, managed-by = "terraform" }
  channels = [google_monitoring_notification_channel.email.id]

  vm_disk = "resource.type = \"gce_instance\" AND metric.type = \"agent.googleapis.com/disk/percent_used\" AND metric.label.state = \"used\" AND metric.label.device = \"/dev/sda1\""

  history_logs = "logName=\"projects/${var.project_id}/logs/gcplogs-docker-driver\" AND jsonPayload.container.name:\"history\""
}

resource "google_monitoring_notification_channel" "email" {
  display_name = "${local.prefix}: e-mail"
  type         = "email"
  labels       = { email_address = local.m.email }
  user_labels  = local.labels
}

resource "google_monitoring_alert_policy" "disk" {
  display_name = "${local.prefix}: a disk is over ${local.m.disk_used_percent}% full"
  combiner     = "OR"

  conditions {
    display_name = "Disk used > ${local.m.disk_used_percent}%"
    condition_threshold {
      filter          = local.vm_disk
      comparison      = "COMPARISON_GT"
      threshold_value = local.m.disk_used_percent
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = "A VM's disk is over ${local.m.disk_used_percent}% full. Usually Docker: old images and build cache. On the VM: `docker system df`, then `docker image prune -a` / `docker builder prune`."
  }
  notification_channels = local.channels
  alert_strategy {
    auto_close = "1800s"
  }
  user_labels = local.labels
}

resource "google_monitoring_alert_policy" "silent" {
  display_name = "${local.prefix}: a VM is silent"
  combiner     = "OR"

  conditions {
    display_name = "No data from the Ops Agent for ${local.m.silence_minutes} min"
    condition_absent {
      filter   = local.vm_disk
      duration = "${local.m.silence_minutes * 60}s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = "A VM sends nothing: it is down, or its Ops Agent stopped (`systemctl status google-cloud-ops-agent`). Also opens once when a VM is removed on purpose (a switch turned all its services off)."
  }
  notification_channels = local.channels
  alert_strategy {
    auto_close = "1800s"
  }
  user_labels = local.labels
}

resource "google_monitoring_uptime_check_config" "site" {
  count        = local.domain != "" ? 1 : 0
  display_name = "${local.prefix}: the site and its database"
  timeout      = "10s"
  period       = "300s"

  http_check {
    path         = local.m.uptime_path
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type   = "uptime_url"
    labels = { project_id = var.project_id, host = local.domain }
  }

  content_matchers {
    content = "\"db_ok\":\\s*true"
    matcher = "MATCHES_REGEX"
  }

  user_labels = local.labels
}

resource "google_monitoring_alert_policy" "site" {
  count        = length(google_monitoring_uptime_check_config.site)
  display_name = "${local.prefix}: the site or its database is down"
  combiner     = "OR"

  conditions {
    display_name = "The uptime check fails from more than one region"
    condition_threshold {
      filter          = "resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.label.check_id = \"${google_monitoring_uptime_check_config.site[0].uptime_check_id}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "60s"
      aggregations {
        alignment_period     = "600s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.host"]
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = "https://${local.domain}${local.m.uptime_path} does not answer \"db_ok\": true. Open it: db_error says why. Then: the tunnel (docker logs cloudflared), History, the database."
  }
  notification_channels = local.channels
  alert_strategy {
    auto_close = "1800s"
  }
  user_labels = local.labels
}

resource "google_logging_metric" "snapshots_stored" {
  name        = "${local.prefix}/snapshots_stored"
  description = "History stored a snapshot (its log line \"stored snapshot: ...\")"
  filter      = "${local.history_logs} AND jsonPayload.message:\"stored snapshot\""
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_monitoring_alert_policy" "no_snapshots" {
  display_name = "${local.prefix}: no new data"
  combiner     = "OR"

  conditions {
    display_name = "No snapshot stored for ${local.m.silence_minutes} min"
    condition_absent {
      filter   = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.snapshots_stored.name}\""
      duration = "${local.m.silence_minutes * 60}s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = "History stores nothing: the chain Fetcher -> queue -> History -> database is broken somewhere. See the alert about poll failures (its reason), and the logs of history and fetcher."
  }
  notification_channels = local.channels
  alert_strategy {
    auto_close = "1800s"
  }
  user_labels = local.labels
}

resource "google_logging_metric" "poll_failures" {
  name        = "${local.prefix}/poll_failures"
  description = "History could not poll (its log line \"poll failed (fetcher|database): ...\")"
  filter      = "${local.history_logs} AND jsonPayload.message:\"poll failed\""
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    labels {
      key         = "reason"
      value_type  = "STRING"
      description = "fetcher or database"
    }
  }
  label_extractors = {
    reason = "REGEXP_EXTRACT(jsonPayload.message, \"poll failed [(]([a-z]+)[)]\")"
  }
}

resource "google_monitoring_alert_policy" "poll_failures" {
  display_name = "${local.prefix}: polls fail"
  combiner     = "OR"

  conditions {
    display_name = "More than ${local.m.poll_failures} failed polls in 15 min"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.poll_failures.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = local.m.poll_failures
      duration        = "0s"
      aggregations {
        alignment_period     = "900s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["metric.label.reason"]
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = "History's polls fail. reason=fetcher: the Fetcher or the queue (docker logs fetcher). reason=database: the database (a wrong password? the role database_check of the playbook site says)."
  }
  notification_channels = local.channels
  alert_strategy {
    auto_close = "1800s"
  }
  user_labels = local.labels
}

resource "google_monitoring_alert_policy" "cloudsql_disk" {
  count        = var.config.database.type == "cloudsql" ? 1 : 0
  display_name = "${local.prefix}: the Cloud SQL disk is over ${local.m.disk_used_percent}% full"
  combiner     = "OR"

  conditions {
    display_name = "Cloud SQL disk used > ${local.m.disk_used_percent}%"
    condition_threshold {
      filter          = "resource.type = \"cloudsql_database\" AND metric.type = \"cloudsql.googleapis.com/database/disk/utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = local.m.disk_used_percent / 100
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = "Cloud SQL grows its disk by itself (disk_autoresize), so this is about cost: the snapshot tables grow every minute."
  }
  notification_channels = local.channels
  alert_strategy {
    auto_close = "1800s"
  }
  user_labels = local.labels
}