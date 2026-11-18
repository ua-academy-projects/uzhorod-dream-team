output "network_id" {
  description = "The VPC (Cloud SQL is connected to it)"
  value       = google_compute_network.vpc.id
}

output "subnet_id" {
  value = google_compute_subnetwork.private.id
}

output "firewall" {
  description = "The network tags a VM gets: the firewall opens SSH for the bastion's tag; the other VMs need none"
  value       = { bastion = [local.bastion_tag], vm = [] }
}
