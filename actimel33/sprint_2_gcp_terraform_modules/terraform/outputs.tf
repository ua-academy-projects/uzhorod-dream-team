output "infrastructure_ips" {
  description = "List of all VMs and it internal IPs"
  value = {
    for name, instance in module.compute_instances : name => instance.private_ip
  }
}

output "artifact_registry_uri" {
  description = "Where to docker push the images"
  value       = module.artifact_registry.registry_uri
}

output "load_balancer_ip" {
  description = "Public IP of the load balancer, the domain must point to it"
  value       = module.load_balancer.lb_public_ip_address
}
