# METRICS that do not come from the logs:
#   CPU          - Google measures it for every VM by itself
#   root disk    - the Ops Agent on every VM (Ansible role ops_agent)
#   site uptime  - the uptime check below

locals {
  metric_filter = {
    cpu = "metric.type=\"compute.googleapis.com/instance/cpu/utilization\" AND resource.type=\"gce_instance\""

    disk = "metric.type=\"agent.googleapis.com/disk/percent_used\" AND resource.type=\"gce_instance\" AND metric.label.state=\"used\" AND metric.label.device=\"/dev/sda1\""

    uptime = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.label.check_id=\"${google_monitoring_uptime_check_config.site.uptime_check_id}\""
  }
}

resource "google_monitoring_uptime_check_config" "site" {
  display_name = "${var.config.prefix}: site"
  period       = "300s"
  timeout      = "10s"
  user_labels  = local.labels

  http_check {
    path         = "/api/status"
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = var.config.tls.domain
    }
  }

  content_matchers {
    content = "\"db_ok\":\\s*true"
    matcher = "MATCHES_REGEX"
  }
}
