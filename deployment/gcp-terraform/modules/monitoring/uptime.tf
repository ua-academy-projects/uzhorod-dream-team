resource "google_monitoring_uptime_check_config" "ui" {
  count = local.monitoring.uptime_check == null ? 0 : 1

  project      = var.cfg.google.project_id
  display_name = local.monitoring.uptime_check.display_name
  period       = "${local.monitoring.uptime_check.period_s}s"
  timeout      = "${local.monitoring.uptime_check.timeout_s}s"

  http_check {
    path           = local.monitoring.uptime_check.path
    port           = 443
    use_ssl        = true
    validate_ssl   = true
    request_method = "GET"

    accepted_response_status_codes {
      status_class = "STATUS_CLASS_2XX"
    }
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.cfg.google.project_id
      host       = coalesce(local.monitoring.uptime_check.host, var.cfg.cloudflare.domain)
    }
  }
}
