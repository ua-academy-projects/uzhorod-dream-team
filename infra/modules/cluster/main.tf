locals {
  nodes   = try(var.config.k3s.nodes, {})
  servers = sort([for name, node in local.nodes : name if node.role == "server"])
  cloud   = length(local.nodes) > 0 ? coalesce(var.config.k3s.cloud, var.config.default_cloud) : null
  clouds  = var.config.clouds
}

module "gcp" {
  source = "./gcp"
  count  = local.cloud == "gcp" ? 1 : 0

  config           = var.config
  region           = local.clouds.gcp.location.regions[var.config.region]
  zone             = local.clouds.gcp.location.zones[var.config.zone]
  subnet_cidr      = local.clouds.gcp.network.subnet_cidr
  network_id       = var.networks.gcp.network_id
  subnet_id        = var.networks.gcp.subnet_id
  api_nlb_ip_index = var.config.k3s.api_nlb_ip_index
  servers          = { for name in local.servers : name => var.instances[name].id }
}

