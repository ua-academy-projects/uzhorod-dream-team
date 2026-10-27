output "registry_uri" {
  description = "Address for docker tag and docker push"
  value       = google_artifact_registry_repository.this.registry_uri
}
