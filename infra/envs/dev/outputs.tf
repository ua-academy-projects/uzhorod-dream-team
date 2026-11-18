output "bastion_ip" {
  description = "The only public address"
  value       = module.vm.bastion_ip
}

output "ssh" {
  description = "Log in to a VM through the bastion (the bastion itself has no shell). First: ansible-playbook citybikes.infra.access"
  value       = module.vm.ssh
}

output "secrets" {
  description = "The secrets to fill in, per cloud (Terraform makes them empty), and the VMs that read each"
  value       = module.secrets.readers
}

output "database" {
  description = "Which PostgreSQL the application uses (database.type), and its private address"
  value = {
    type    = jsondecode(file("${path.module}/../../config.json")).database.type
    address = module.database.address
  }
}

output "dashboard_url" {
  description = "The CityBikes overview dashboard"
  value       = module.monitoring.dashboard_url
}
