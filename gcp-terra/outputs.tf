output "bastion_public_ip" {
  description = "Public IP of Bastion VM"
  value       = try(module.compute.public_ips["bastion"], null)
}

output "artifact_registry" {
  description = "Application image repository"
  value       = "${local.config.region}-docker.pkg.dev/${local.config.project_id}/${local.config.registry.repository_id}"
}

output "ui_public_ip" {
  description = "Static public IP of the UI VM"
  value       = module.compute.public_ips["ui"]
}
