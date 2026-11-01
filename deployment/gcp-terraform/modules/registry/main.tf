locals {
  repo_id    = google_artifact_registry_repository.main_repo.repository_id
  project_id = var.cfg.google.project_id
  location   = var.cfg.google.region
}

resource "google_artifact_registry_repository" "main_repo" {
  project       = local.project_id
  location      = local.location
  repository_id = var.cfg.registry.id
  description   = var.cfg.registry.description
  format        = "DOCKER"
}
