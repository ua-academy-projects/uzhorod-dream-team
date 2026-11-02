output "networks" {
  value = { for key, network in google_compute_network.vpc : key => network.name }
}

output "subnets" {
  value = { for key, subnet in google_compute_subnetwork.subnet : key => subnet.id }
}
