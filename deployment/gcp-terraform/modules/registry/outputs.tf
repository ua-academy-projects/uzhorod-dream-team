output "repo_id" {
  value = google_artifact_registry_repository.main_repo.id
}

output "repository_url" {
  value = "${var.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.main_repo.repository_id}"
}
