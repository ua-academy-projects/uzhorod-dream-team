output "api_address" {
  description = "The private address of the control plane's API (the load balancer, port 6443); null without a cluster"
  value       = one(concat([for cluster in module.gcp : cluster.api_address]))
}
