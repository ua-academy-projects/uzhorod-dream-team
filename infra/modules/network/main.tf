locals {
  clouds = distinct(concat([var.config.default_cloud], [for vm in values(var.config.vms.instances) : coalesce(vm.cloud, var.config.default_cloud)]))
}

module "gcp" {
  source = "./gcp"
  count  = contains(local.clouds, "gcp") ? 1 : 0

  config            = var.config
  region            = var.config.clouds.gcp.location.regions[var.config.region]
  subnet_cidr       = var.config.clouds.gcp.network.subnet_cidr
  ssh_allowed_cidrs = var.ssh_allowed_cidrs
}
