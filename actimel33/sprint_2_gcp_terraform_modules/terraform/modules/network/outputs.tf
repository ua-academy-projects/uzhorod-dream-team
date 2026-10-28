output "network_self_link" {
  description = "The VPC, for firewall rules"
  value       = google_compute_network.vpc.self_link
}
output "edge_subnetwork_self_link" {
  value = google_compute_subnetwork.edge.self_link
}
output "private_subnetwork_self_link" {
  value = google_compute_subnetwork.private.self_link
}
output "network_id" {
  value = google_compute_network.vpc.id
}
