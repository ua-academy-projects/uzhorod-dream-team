locals {
  repo_id = google_artifact_registry_repository.main_repo.repository_id
}

resource "google_artifact_registry_repository" "main_repo" {
  project = var.project_id
  location = var.repository.location
  repository_id = var.repository.id
  description = var.repository.description
  format = "DOCKER"
}
