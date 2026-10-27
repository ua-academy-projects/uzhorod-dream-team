output "infrastructure_ips" {
  description = "List of all VMs and it internal IPs"
  value = {
    for name, instance in module.compute_instances : name => instance.private_ip
  }
}
