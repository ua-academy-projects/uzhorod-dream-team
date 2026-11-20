output "by_cloud" {
  description = "cloud => { network_id, subnet_id, firewall, ... } for every cloud with a network; firewall = { bastion = [...], vm = [...] } (GCP: network tags, AWS: security groups); AWS adds public_subnet_id, private_route_table_id, database_subnet_ids"
  value = merge(
    { for network in module.gcp : "gcp" => network },
    { for network in module.aws : "aws" => network },
  )
}
