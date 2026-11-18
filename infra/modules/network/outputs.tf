output "by_cloud" {
  description = "cloud => { network_id, subnet_id, firewall } for every cloud with a network; firewall = { bastion = [...], vm = [...] } (GCP: network tags, AWS: security groups)"
  value       = { for network in module.gcp : "gcp" => network }
}
