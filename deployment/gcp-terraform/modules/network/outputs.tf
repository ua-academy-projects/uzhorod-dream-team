output "network_id" {
  value = google_compute_network.main.id
}

output "subnetwork_id" {
  value = google_compute_subnetwork.private.id
}

output "private_ips" {
  value = { for name, address in google_compute_address.private : name => address.address }
}

output "public_ips" {
  value = { for name, address in google_compute_address.public : name => address.address }
}

output "vm_tags" {
  value = local.vm_tags
}
