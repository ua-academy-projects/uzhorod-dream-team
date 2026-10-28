output "lb_public_ip_address" {
  description = "Dedicated public IP for the load balancer for DNS configuration"
  value       = google_compute_global_address.lb_public_ip.address
}
