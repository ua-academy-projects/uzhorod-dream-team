resource "google_artifact_registry_repository" "this" {
  location      = var.location
  repository_id = var.repository_id
  format        = var.format
  description   = var.description
  labels        = var.labels
}

# VMs may pull images from repository.
resource "google_artifact_registry_repository_iam_member" "reader" {
  for_each = var.reader_emails

  location   = google_artifact_registry_repository.this.location
  repository = google_artifact_registry_repository.this.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${each.value}"
}
