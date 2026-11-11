output "url" {
  value = "${var.config.region}-docker.pkg.dev/${var.config.project_id}/${var.config.registry.repository_id}"
}
