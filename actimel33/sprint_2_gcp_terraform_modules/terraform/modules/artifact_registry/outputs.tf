output "repository" {
  description = "The repository: its id, location, name and the address for docker push"
  value = {
    repository_id = google_artifact_registry_repository.images.repository_id
    location      = google_artifact_registry_repository.images.location
    name          = google_artifact_registry_repository.images.name
    registry_uri  = google_artifact_registry_repository.images.registry_uri
  }
}
