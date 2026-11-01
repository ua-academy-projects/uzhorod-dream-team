output "network_id" {
  description = "VPC ID"
  value       = google_compute_network.analyzer.id
}

output "subnet_id" {
  description = "Subnetwork ID"
  value       = google_compute_subnetwork.analyzer.id
}
