output "self_link" {
  description = "The VPC, for firewall rules"
  value       = google_compute_network.vpc.self_link
}

output "subnets" {
  description = "Subnet role (private, management) => self_link"
  value = {
    private    = google_compute_subnetwork.private.self_link
    management = google_compute_subnetwork.management.self_link
  }

  depends_on = [google_compute_router_nat.nat]
}
