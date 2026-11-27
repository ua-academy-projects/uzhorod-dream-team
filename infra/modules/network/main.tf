

locals {
  k3s_clouds = length(try(var.config.k3s.nodes, {})) > 0 ? [coalesce(var.config.k3s.cloud, var.config.default_cloud)] : []
  clouds     = distinct(concat([var.config.default_cloud], [for vm in values(var.config.vms.instances) : coalesce(vm.cloud, var.config.default_cloud)], local.k3s_clouds))
  aws        = var.config.clouds.aws

  peers = { for cloud in local.clouds : cloud => [for other in local.clouds : var.config.clouds[other].network.subnet_cidr if other != cloud] }
}

module "gcp" {
  source = "./gcp"
  count  = contains(local.clouds, "gcp") ? 1 : 0

  config            = var.config
  region            = var.config.clouds.gcp.location.regions[var.config.region]
  subnet_cidr       = var.config.clouds.gcp.network.subnet_cidr
  peer_cidrs        = local.peers.gcp
  ssh_allowed_cidrs = var.ssh_allowed_cidrs
}

module "aws" {
  source = "./aws"
  count  = contains(local.clouds, "aws") ? 1 : 0

  config            = var.config
  network           = local.aws.network
  zone              = local.aws.location.zones[var.config.zone]
  database_zone     = [for word, zone in local.aws.location.zones : zone if word != var.config.zone][0]
  peer_cidrs        = local.peers.aws
  ssh_allowed_cidrs = var.ssh_allowed_cidrs
  account_id        = var.aws_account_id
}