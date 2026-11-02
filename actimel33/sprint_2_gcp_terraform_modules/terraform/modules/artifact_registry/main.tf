resource "google_artifact_registry_repository" "images" {
  location      = var.config.project.region
  repository_id = var.config.registry.repository_id
  format        = var.config.registry.format
  description   = var.config.registry.description
  labels        = var.config.project.labels
}
