output "network_id" {
  value = google_compute_network.main.id
}

output "subnetwork_id" {
  value = google_compute_subnetwork.private.id
}

output "public_ips" {
  value = { for name, address in google_compute_address.public : name => address.address }
}
