locals {
  thresholds = { for k, v in var.config.monitoring.alerts : k => v.threshold == null ? "" : format("%g", v.threshold) }

  requests      = "${var.promql.iss_nginx_requests}{monitored_resource=\"gce_instance\"}"
  requests_5xx  = "${var.promql.iss_nginx_requests}{monitored_resource=\"gce_instance\",class=\"5\"}"
  requests_5024 = "${var.promql.iss_nginx_requests}{monitored_resource=\"gce_instance\",status=~\"502|504\"}"
  stored        = "${var.promql.iss_positions}{monitored_resource=\"gce_instance\",event=\"stored\"}"
  errors        = "${var.promql.iss_container_errors}{monitored_resource=\"gce_instance\"}"

  history_hint = "Check history: `ssh gcp-${local.prefix}-history`, then `sudo docker ps` and `sudo docker logs iss-history-1`; the dashboard log panels show the errors."

  definitions = {
    nginx_5xx_share = {
      title    = "nginx 5xx share"
      severity = "WARNING"
      kind     = "promql"
      query    = "sum(rate(${local.requests_5xx}[5m])) / sum(rate(${local.requests}[5m])) > ${local.thresholds.nginx_5xx_share}"
      content  = "More than ${local.thresholds.nginx_5xx_share} of the requests to the site end with 5xx. ${local.history_hint}"
    }
    history_unreachable = {
      title    = "history unreachable"
      severity = "CRITICAL"
      kind     = "promql"
      query    = "sum(increase(${local.requests_5024}[5m])) > 0"
      content  = "nginx answered 502 or 504: history is down or too slow. ${local.history_hint}"
    }
    positions_stalled = {
      title    = "positions stalled"
      severity = "CRITICAL"
      kind     = "promql"
      query    = "(sum(increase(${local.stored}[5m])) or vector(0)) < 1"
      content  = "history stored no ISS position in the last 5 minutes. Check fetcher (`ssh gcp-${local.prefix}-fetcher`, `sudo docker logs iss-fetcher-1`), the queue on db and history. Fires once on a new stand until deploy.yml has finished."
    }
    app_errors = {
      title    = "container errors"
      severity = "WARNING"
      kind     = "promql"
      query    = "sum(increase(${local.errors}[5m])) > ${local.thresholds.app_errors}"
      content  = "More than ${local.thresholds.app_errors} error lines from the containers in 5 minutes. The dashboard panel Error lines by container shows which one; the Error log panel shows the lines."
    }
    agent_missing = {
      title    = "agent missing"
      severity = "CRITICAL"
      kind     = "absent"
      filter   = "${local.vm_filter} AND metric.type = \"agent.googleapis.com/agent/uptime\""
      aligner  = "ALIGN_RATE"
      period   = "60s"
      content  = "A VM sends no Ops Agent metrics: the VM is stopped or the agent stopped. On the VM: `sudo systemctl status google-cloud-ops-agent`; rerun `./scripts/ansible.sh platform.yml`."
    }
    disk_percent = {
      title    = "disk used"
      severity = "WARNING"
      kind     = "threshold"
      filter   = "${local.vm_filter} AND metric.type = \"agent.googleapis.com/disk/percent_used\" AND metric.label.state = \"used\" AND ${local.disk_device}"
      aligner  = "ALIGN_MEAN"
      period   = "60s"
      content  = "A disk of a VM is more than ${local.thresholds.disk_percent} % used. Run `./scripts/docker-stats.sh`, then `sudo docker image prune -a` on the VM or raise `disk_gb` in config.json."
    }
    memory_percent = {
      title    = "memory used"
      severity = "WARNING"
      kind     = "threshold"
      filter   = "${local.vm_filter} AND metric.type = \"agent.googleapis.com/memory/percent_used\" AND metric.label.state = \"used\""
      aligner  = "ALIGN_MEAN"
      period   = "60s"
      content  = "A VM uses more than ${local.thresholds.memory_percent} % of its memory. Run `./scripts/docker-stats.sh`; raise `machine_type` in config.json if it stays high."
    }
    cloudsql_cpu = {
      title    = "Cloud SQL CPU"
      severity = "WARNING"
      kind     = "threshold"
      filter   = "${local.sql_filter} AND metric.type = \"cloudsql.googleapis.com/database/cpu/utilization\""
      aligner  = "ALIGN_MEAN"
      period   = "60s"
      content  = "Cloud SQL CPU utilization is above ${local.thresholds.cloudsql_cpu}. Check Query insights in the console; raise `cloudsql.tier` if it stays high."
    }
    cloudsql_disk = {
      title    = "Cloud SQL disk"
      severity = "WARNING"
      kind     = "threshold"
      filter   = "${local.sql_filter} AND metric.type = \"cloudsql.googleapis.com/database/disk/utilization\""
      aligner  = "ALIGN_MEAN"
      period   = "300s"
      content  = "Cloud SQL disk utilization is above ${local.thresholds.cloudsql_disk}. Raise `cloudsql.disk_gb` and run `./scripts/tf.sh apply`."
    }
  }

  policies = {
    for k, v in local.alerts : k => merge({ query = null, filter = null, aligner = null, period = null }, local.definitions[k], v)
  }
}

resource "google_monitoring_alert_policy" "this" {
  for_each = local.policies

  display_name          = "${local.prefix} ${each.value.title}"
  combiner              = "OR"
  severity              = each.value.severity
  notification_channels = [for c in google_monitoring_notification_channel.email : c.id]
  user_labels           = local.labels

  conditions {
    display_name = each.value.title

    dynamic "condition_prometheus_query_language" {
      for_each = each.value.kind == "promql" ? [1] : []
      content {
        query                     = each.value.query
        duration                  = "${each.value.duration_s}s"
        evaluation_interval       = "60s"
        disable_metric_validation = true
      }
    }

    dynamic "condition_threshold" {
      for_each = each.value.kind == "threshold" ? [1] : []
      content {
        filter          = each.value.filter
        comparison      = "COMPARISON_GT"
        threshold_value = each.value.threshold
        duration        = "${each.value.duration_s}s"

        aggregations {
          alignment_period   = each.value.period
          per_series_aligner = each.value.aligner
        }
      }
    }

    dynamic "condition_absent" {
      for_each = each.value.kind == "absent" ? [1] : []
      content {
        filter   = each.value.filter
        duration = "${each.value.duration_s}s"

        aggregations {
          alignment_period   = each.value.period
          per_series_aligner = each.value.aligner
        }
      }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "[${local.prefix}] ${each.value.title}"
    content   = each.value.content
  }
}
