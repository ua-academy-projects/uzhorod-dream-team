resource "google_project_service" "artifact_registry" {
  project            = local.config.project_id
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "application" {
  project       = local.config.project_id
  location      = local.config.region
  repository_id = local.config.registry.repository_id
  format        = "DOCKER"
  docker_config {
    immutable_tags = true
  }
  depends_on = [google_project_service.artifact_registry]
}

resource "google_artifact_registry_repository_iam_member" "reader" {
  for_each   = toset(["fetcher", "history", "ui"])
  project    = local.config.project_id
  location   = google_artifact_registry_repository.application.location
  repository = google_artifact_registry_repository.application.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${module.secrets.service_account_emails[each.key]}"
}

resource "google_artifact_registry_repository_iam_member" "publisher" {
  for_each   = var.image_publishers
  project    = local.config.project_id
  location   = google_artifact_registry_repository.application.location
  repository = google_artifact_registry_repository.application.name
  role       = "roles/artifactregistry.writer"
  member     = each.value
}
