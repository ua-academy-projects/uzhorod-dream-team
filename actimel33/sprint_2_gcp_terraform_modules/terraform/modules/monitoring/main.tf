locals {
  monitoring = var.config.monitoring
  domain     = var.config.load_balancer.domain

  uptime_filter   = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\" AND resource.label.host=\"${local.domain}\""
  requests_filter = "metric.type=\"loadbalancing.googleapis.com/https/request_count\" AND resource.type=\"https_lb_rule\" AND resource.label.forwarding_rule_name=\"${var.https_rule}\""
  cpu_filter      = "metric.type=\"compute.googleapis.com/instance/cpu/utilization\" AND resource.type=\"gce_instance\""
  memory_filter   = "metric.type=\"agent.googleapis.com/memory/percent_used\" AND resource.type=\"gce_instance\" AND metric.label.state=\"used\""
  disk_filter     = "metric.type=\"agent.googleapis.com/disk/percent_used\" AND resource.type=\"gce_instance\" AND metric.label.state=\"used\" AND metric.label.device=monitoring.regex.full_match(\"/dev/sd[a-z]1?\")"
}

resource "google_monitoring_notification_channel" "email" {
  display_name = "Alerts of crypto-price-service"
  type         = "email"

  labels = {
    email_address = local.monitoring.notification_email
  }
}

resource "google_monitoring_uptime_check_config" "health" {
  display_name     = "Health of ${local.domain}"
  timeout          = "10s"
  period           = "60s"
  selected_regions = local.monitoring.uptime_check_regions

  http_check {
    path         = local.monitoring.uptime_check_path
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.config.project.id
      host       = local.domain
    }
  }

  content_matchers {
    content = local.monitoring.uptime_check_content
    matcher = "CONTAINS_STRING"
  }
}

resource "google_monitoring_alert_policy" "site_down" {
  display_name          = "Site ${local.domain} is down"
  combiner              = "OR"
  severity              = "CRITICAL"
  notification_channels = [google_monitoring_notification_channel.email.id]

  conditions {
    display_name = "The health check fails in more than one region"

    condition_threshold {
      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"
      filter                  = local.uptime_filter
      comparison              = "COMPARISON_GT"
      threshold_value         = 1
      duration                = "120s"

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.host"]
      }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "https://${local.domain}${local.monitoring.uptime_check_path} does not answer `${local.monitoring.uptime_check_content}`. Check `curl -s https://${local.domain}${local.monitoring.uptime_check_path}`, then `ssh history sudo systemctl status crypto-history.service` and `ssh ui sudo systemctl status crypto-ui.service`."
  }
}

resource "google_monitoring_alert_policy" "cpu" {
  display_name          = "High CPU on a VM"
  combiner              = "OR"
  severity              = "WARNING"
  notification_channels = [google_monitoring_notification_channel.email.id]

  conditions {
    display_name = "CPU above ${local.monitoring.cpu_threshold * 100}% for 5 minutes"

    condition_threshold {
      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"
      filter                  = local.cpu_filter
      comparison              = "COMPARISON_GT"
      threshold_value         = local.monitoring.cpu_threshold
      duration                = "300s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "The VM named in the alert is busy. Look at `ssh <vm> top` and the CPU chart of the dashboard."
  }
}

resource "google_monitoring_alert_policy" "memory" {
  display_name          = "Low memory on a VM"
  combiner              = "OR"
  severity              = "WARNING"
  notification_channels = [google_monitoring_notification_channel.email.id]

  conditions {
    display_name = "Memory used above ${local.monitoring.memory_threshold_percent}% for 5 minutes"

    condition_threshold {
      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"
      filter                  = local.memory_filter
      comparison              = "COMPARISON_GT"
      threshold_value         = local.monitoring.memory_threshold_percent
      duration                = "300s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "The VM named in the alert is running out of memory (Ops Agent). Look at `ssh <vm> free -m` and `ssh <vm> sudo docker stats --no-stream`."
  }
}

resource "google_monitoring_alert_policy" "errors" {
  display_name          = "5xx errors on the load balancer"
  combiner              = "OR"
  severity              = "ERROR"
  notification_channels = [google_monitoring_notification_channel.email.id]

  conditions {
    display_name = "More than ${local.monitoring.lb_5xx_ratio_threshold * 100}% of the requests get 5xx in 5 minutes"

    condition_threshold {
      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"
      filter                  = "${local.requests_filter} AND metric.label.response_code_class=\"500\""
      denominator_filter      = local.requests_filter
      comparison              = "COMPARISON_GT"
      threshold_value         = local.monitoring.lb_5xx_ratio_threshold
      duration                = "60s"

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

  documentation {
    mime_type = "text/markdown"
    content   = "The site answers with 5xx. 502 and 503 mean the load balancer cannot reach ui: `ssh ui sudo systemctl status crypto-ui.service`. 500 comes from history: `ssh history sudo journalctl -u crypto-history.service -n 50`."
  }
}
