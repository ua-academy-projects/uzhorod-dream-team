locals {
  cloud   = var.config.default_cloud
  tables  = var.config.clouds[local.cloud]
  managed = var.config.database.type == "managed"

  postgres_vm = var.config.vms.instances[var.config.database.vm]
}

module "gcp" {
  source = "./gcp"
  count  = local.managed && local.cloud == "gcp" ? 1 : 0

  config     = var.config
  network_id = var.networks.gcp.network_id
  region     = local.tables.location.regions[var.config.region]
  zone       = local.tables.location.zones[var.config.zone]
  size       = local.tables.database.sizes[var.config.database.managed.size]
}

module "aws" {
  source = "./aws"
  count  = local.managed && local.cloud == "aws" ? 1 : 0

  config = var.config
  network = {
    network_id          = var.networks.aws.network_id
    database_subnet_ids = var.networks.aws.database_subnet_ids
    vm_firewall         = var.networks.aws.firewall.vm
  }
  zone = local.tables.location.zones[var.config.zone]
  size = local.tables.database.sizes[var.config.database.managed.size]
}
