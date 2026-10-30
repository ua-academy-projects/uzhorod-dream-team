resource "google_artifact_registry_repository" "this" {
  location      = var.project.region
  repository_id = var.config.repository_id
  format        = var.config.format
  description   = var.config.description
  labels        = var.project.labels
}
