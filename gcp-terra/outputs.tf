output "bastion_public_ip" {
  description = "Public IP of Bastion VM"
  value       = module.compute.public_ips["bastion"]
}

output "ui_public_ip" {
  description = "Static public IP of the UI VM"
  value       = module.compute.public_ips["ui"]
}
