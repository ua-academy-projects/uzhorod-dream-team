resource "google_project_iam_member" "metric_writer" {
  for_each = local.agent_accounts
  project  = var.config.project_id
  role     = "roles/monitoring.metricWriter"
  member   = "serviceAccount:${each.value}"
}

resource "google_project_iam_member" "log_writer" {
  for_each   = { for key, email in local.agent_accounts : key => email if var.monitoring.agent.write_logs }
  project    = var.config.project_id
  role       = "roles/logging.logWriter"
  member     = "serviceAccount:${each.value}"
  depends_on = [google_project_service.logging]
}
