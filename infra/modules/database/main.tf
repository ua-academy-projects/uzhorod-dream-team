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
