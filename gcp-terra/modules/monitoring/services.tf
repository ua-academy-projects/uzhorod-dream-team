resource "google_project_service" "monitoring" {
  count              = local.enabled ? 1 : 0
  project            = var.config.project_id
  service            = "monitoring.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "logging" {
  count              = local.enabled && var.monitoring.agent.enabled && var.monitoring.agent.write_logs ? 1 : 0
  project            = var.config.project_id
  service            = "logging.googleapis.com"
  disable_on_destroy = false
}
