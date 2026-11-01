output "repo_id" {
  value = local.repo_id
}

output "repository_url" {
  value = "${local.location}-docker.pkg.dev/${local.project_id}/${local.repo_id}"
}
