output "network_id" {
  value = google_compute_network.this.id
}

output "subnetwork_id" {
  value = google_compute_subnetwork.this.id
}

output "psa_connection_id" {
  value = one(google_service_networking_connection.psa[*].id)
}

output "ips" {
  value = { for k, a in google_compute_address.internal : k => a.address }
}
