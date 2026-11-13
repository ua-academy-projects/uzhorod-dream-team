output "ip" {
  description = "Public IP of the load balancer, the domain must point to it"
  value       = google_compute_global_address.lb_public_ip.address
}

output "https_rule_name" {
  description = "Name of the HTTPS forwarding rule; its metrics are the requests of the site"
  value       = google_compute_global_forwarding_rule.https.name
}
