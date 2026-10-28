resource "google_artifact_registry_repository_iam_member" "reader" {
  for_each = var.readers

  project = var.project_id
  location = var.location
  repository = google_artifact_registry_repository.main_repo.id
  role = "roles/artifactregistry.reader"
  member = each.value
}

resource "google_artifact_registry_repository_iam_member" "writer" {
  for_each = var.writers

  project = var.project_id
  location = var.location
  repository = google_artifact_registry_repository.main_repo.id
  role = "roles/artifactregistry.writer"
  member = each.value
}
