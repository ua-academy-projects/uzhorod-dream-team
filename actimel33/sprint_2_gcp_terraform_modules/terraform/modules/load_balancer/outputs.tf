output "ip" {
  description = "Public IP of the load balancer, the domain must point to it"
  value       = google_compute_global_address.lb_public_ip.address
}

output "domain" {
  description = "Domain of the site"
  value       = var.config.domain
}
