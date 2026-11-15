resource "google_monitoring_uptime_check_config" "ui" {
  count            = local.enabled && local.config.uptime_check.enabled ? 1 : 0
  project          = var.config.project_id
  display_name     = local.config.uptime_check.display_name
  timeout          = local.config.uptime_check.timeout
  period           = local.config.uptime_check.period
  selected_regions = local.config.uptime_check.regions
  monitored_resource {
    type   = "uptime_url"
    labels = { project_id = var.config.project_id, host = local.ui_host }
  }
  http_check {
    path         = local.config.uptime_check.path
    port         = local.config.uptime_check.port
    use_ssl      = local.config.uptime_check.use_ssl
    validate_ssl = local.config.uptime_check.validate_ssl
    accepted_response_status_codes { status_class = local.config.uptime_check.status_class }
  }
  depends_on = [google_project_service.monitoring]
}
