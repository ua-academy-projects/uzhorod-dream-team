output "network_id" {
  description = "The VPC (Cloud SQL is connected to it)"
  value       = google_compute_network.vpc.id
}

output "subnetwork_id" {
  value = google_compute_subnetwork.private.id
}
