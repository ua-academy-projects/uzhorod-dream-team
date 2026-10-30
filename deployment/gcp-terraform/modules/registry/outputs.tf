output "repo_id" {
  value = local.repo_id
}

output "repository_url" {
  value = "${var.repository.location}-docker.pkg.dev/${var.project_id}/${local.repo_id}"
}
