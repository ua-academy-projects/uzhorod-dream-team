output "infrastructure_ips" {
  description = "VM name => internal IP"
  value       = module.vms.private_ips
}

output "artifact_registry_uri" {
  description = "Where to docker push the images"
  value       = module.artifact_registry.repository.registry_uri
}

output "load_balancer_ip" {
  description = "Public IP of the load balancer, the domain must point to it"
  value       = module.load_balancer.ip
}
