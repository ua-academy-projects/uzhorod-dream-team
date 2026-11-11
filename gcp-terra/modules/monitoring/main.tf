locals {
  enabled           = try(var.config.monitoring.enabled, false)
  sql_instance_name = try(var.config.cloud_sql.managed, false) ? var.config.cloud_sql.instance_name : null
  ui_host           = try(var.public_ips["ui"], null)
  agent_accounts    = { for key, email in var.service_account_emails : key => email if local.enabled && key != "bastion" && contains(keys(var.instance_ids), key) }
  config            = var.config.monitoring
}

resource "google_project_service" "monitoring" {
  count              = local.enabled ? 1 : 0
  project            = var.config.project_id
  service            = "monitoring.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_iam_member" "metric_writer" {
  for_each = local.agent_accounts
  project  = var.config.project_id
  role     = "roles/monitoring.metricWriter"
  member   = "serviceAccount:${each.value}"
}

resource "google_monitoring_notification_channel" "email" {
  count        = local.enabled ? 1 : 0
  project      = var.config.project_id
  display_name = "Data Monitor operator"
  type         = "email"
  labels       = { email_address = local.config.notification_email }
  depends_on   = [google_project_service.monitoring]
}

resource "google_monitoring_uptime_check_config" "ui" {
  count            = local.enabled ? 1 : 0
  project          = var.config.project_id
  display_name     = "Data Monitor HTTPS"
  timeout          = "10s"
  period           = "60s"
  selected_regions = ["EUROPE", "USA", "ASIA_PACIFIC"]
  monitored_resource {
    type   = "uptime_url"
    labels = { project_id = var.config.project_id, host = local.ui_host }
  }
  http_check {
    path         = "/"
    port         = 443
    use_ssl      = true
    validate_ssl = true
    accepted_response_status_codes { status_class = "STATUS_CLASS_2XX" }
  }
  depends_on = [google_project_service.monitoring]
}

locals {
  vm_scope    = "resource.type = \"gce_instance\" AND (${join(" OR ", [for id in values(var.instance_ids) : "resource.labels.instance_id = \"${id}\""])})"
  agent_scope = "resource.type = \"gce_instance\" AND (${join(" OR ", [for key, id in var.instance_ids : "resource.labels.instance_id = \"${id}\"" if key != "bastion"])})"
  sql_scope   = local.sql_instance_name == null ? null : "resource.type = \"cloudsql_database\" AND resource.labels.database_id = \"${var.config.project_id}:${local.sql_instance_name}\""
  metrics = local.enabled ? merge({
    vm_cpu = {
      title     = "VM CPU"
      filter    = "${local.vm_scope} AND metric.type = \"compute.googleapis.com/instance/cpu/utilization\""
      threshold = local.config.cpu_threshold
      scale     = 1
    }
    vm_disk = {
      title     = "VM disk used"
      filter    = "${local.agent_scope} AND metric.type = \"agent.googleapis.com/disk/percent_used\" AND metric.labels.state = \"used\" AND metric.labels.device != starts_with(\"/dev/loop\")"
      threshold = local.config.disk_threshold
      scale     = 100
    }
    vm_memory = {
      title     = "VM memory used"
      filter    = "${local.agent_scope} AND metric.type = \"agent.googleapis.com/memory/percent_used\" AND metric.labels.state = \"used\""
      threshold = local.config.memory_threshold
      scale     = 100
    }
    }, local.sql_instance_name == null ? {} : {
    sql_cpu = {
      title     = "Cloud SQL CPU"
      filter    = "${local.sql_scope} AND metric.type = \"cloudsql.googleapis.com/database/cpu/utilization\""
      threshold = local.config.cpu_threshold
      scale     = 1
    }
    sql_disk = {
      title     = "Cloud SQL disk used"
      filter    = "${local.sql_scope} AND metric.type = \"cloudsql.googleapis.com/database/disk/utilization\""
      threshold = local.config.disk_threshold
      scale     = 1
    }
  }) : {}
}

resource "google_monitoring_alert_policy" "utilization" {
  for_each              = local.metrics
  project               = var.config.project_id
  display_name          = "Data Monitor: ${each.value.title} > ${each.value.threshold * 100}%"
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email[0].name]
  conditions {
    display_name = "Sustained utilization"
    condition_threshold {
      filter          = each.value.filter
      comparison      = "COMPARISON_GT"
      threshold_value = each.value.threshold * each.value.scale
      duration        = local.config.duration
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
      trigger { count = 1 }
    }
  }
  alert_strategy { auto_close = "1800s" }
  documentation {
    mime_type = "text/markdown"
    content   = "Inspect Data Monitor dashboard and the affected resource. CPU: check load; disk: check capacity and logs; memory: inspect processes. Do not remove database volumes."
  }
}

resource "google_monitoring_alert_policy" "uptime" {
  count                 = local.enabled ? 1 : 0
  project               = var.config.project_id
  display_name          = "Data Monitor: HTTPS unavailable"
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email[0].name]
  conditions {
    display_name = "At least two failing checkers for 3 minutes"
    condition_threshold {
      filter          = "resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.labels.check_id = \"${google_monitoring_uptime_check_config.ui[0].uptime_check_id}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "180s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.labels.host"]
      }
      trigger { count = 1 }
    }
  }
  alert_strategy { auto_close = "1800s" }
  documentation {
    mime_type = "text/markdown"
    content   = "Check UI VM, nginx, certificate renewal, and History health. HTTPS checks validate the certificate and require a 2xx response at /."
  }
}

resource "google_monitoring_dashboard" "overview" {
  count   = local.enabled ? 1 : 0
  project = var.config.project_id
  dashboard_json = jsonencode({
    displayName = "Data Monitor overview"
    gridLayout = {
      columns = "2"
      widgets = concat([for key, metric in local.metrics : {
        title = metric.title
        xyChart = {
          dataSets = [{
            timeSeriesQuery = {
              timeSeriesFilter = {
                filter      = metric.filter
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MEAN" }
              }
            }
            plotType   = "LINE"
            targetAxis = "Y1"
          }]
          yAxis      = { label = metric.scale == 100 ? "%" : "ratio (0–1)", scale = "LINEAR" }
          thresholds = [{ value = metric.threshold * metric.scale }]
        }
        }], [{
        title = "HTTPS successful checkers"
        xyChart = {
          dataSets = [{
            timeSeriesQuery = {
              timeSeriesFilter = {
                filter      = "resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.labels.check_id = \"${google_monitoring_uptime_check_config.ui[0].uptime_check_id}\""
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_FRACTION_TRUE" }
              }
            }
            plotType   = "LINE"
            targetAxis = "Y1"
          }]
          yAxis = { label = "success fraction", scale = "LINEAR" }
        }
      }])
    }
  })
}
