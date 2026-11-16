output "bastion_ip" {
  description = "The only public address"
  value       = one(module.gcp[*].bastion_ip)
}

output "placement" {
  description = "Which VM runs what, at which address"
  value       = one(module.gcp[*].placement)
}

output "ssh" {
  description = "Log in to a VM through the bastion (the bastion itself has no shell). First: ansible-playbook citybikes.infra.access"
  value       = one(module.gcp[*].ssh)
}

output "database" {
  description = "Which PostgreSQL the application uses (database.type), and its private address"
  value       = one(module.gcp[*].database)
}

output "dashboard_url" {
  description = "The CityBikes overview dashboard in the Cloud console"
  value       = one(module.gcp[*].dashboard_url)
}
