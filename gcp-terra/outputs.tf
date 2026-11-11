output "bastion_public_ip" {
  description = "Public IP of Bastion VM"
  value       = try(module.compute.public_ips["bastion"], null)
}

output "artifact_registry" {
  description = "Application image repository"
  value       = module.registry.url
}

output "ui_public_ip" {
  description = "Static public IP of the UI VM"
  value       = module.compute.public_ips["ui"]
}

output "cloud_sql_connection_name" {
  value = try(module.cloud_sql[0].connection_name, null)
}
