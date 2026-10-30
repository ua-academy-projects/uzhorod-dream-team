output "repository" {
  description = "The repository: its id, location, name and the address for docker push"
  value = {
    repository_id = google_artifact_registry_repository.this.repository_id
    location      = google_artifact_registry_repository.this.location
    name          = google_artifact_registry_repository.this.name
    registry_uri  = google_artifact_registry_repository.this.registry_uri
  }
}
