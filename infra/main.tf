module "layout" {
  source = "./modules/layout"

  config = local.cfg
}

module "network" {
  source = "./modules/network"

  config = local.cfg
}

module "iam" {
  source = "./modules/iam"

  config  = local.cfg
  vm_keys = module.layout.vm_keys
}

module "cloudsql" {
  source = "./modules/cloudsql"
  count  = try(local.cfg.app.POSTGRES_BACKEND, "") == "cloudsql" ? 1 : 0

  config     = local.cfg
  network_id = module.network.network_id
  iam_users  = module.iam.db_user_names

  depends_on = [module.network]
}

module "firewall" {
  source = "./modules/firewall"

  config     = local.cfg
  network_id = module.network.network_id
}

module "cloud_init" {
  source = "./modules/cloud-init"

  config = local.cfg
  ips    = module.network.ips
}

module "vm" {
  source   = "./modules/vm"
  for_each = module.layout.vm_keys

  config          = local.cfg
  key             = each.key
  subnetwork_id   = module.network.subnetwork_id
  ip              = module.network.ips[each.key]
  user_data       = module.cloud_init.user_data[each.key]
  service_account = lookup(module.iam.emails, each.key, null)

  depends_on = [module.network]
}

module "monitoring" {
  source = "./modules/monitoring"
  count  = local.cfg.monitoring.ops_agent ? 1 : 0

  config = local.cfg

  depends_on = [module.vm]
}
