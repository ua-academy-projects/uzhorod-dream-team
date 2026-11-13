module "network" {
  source = "./modules/network"

  config = local.config
}

module "firewall" {
  source = "./modules/firewall"

  config   = local.config
  networks = module.network.networks
}

module "service_accounts" {
  source = "./modules/service_accounts"

  config     = local.config
  project_id = var.project_id
}

module "secrets" {
  source = "./modules/secrets"

  config           = local.config
  service_accounts = module.service_accounts.emails
}

module "vms" {
  source = "./modules/vms"

  config           = local.config
  networks         = module.network.networks
  subnets          = module.network.subnets
  service_accounts = module.service_accounts.emails
}

module "dns" {
  source = "./modules/dns"

  config = local.config
}

module "monitoring" {
  source = "./modules/monitoring"

  config      = local.config
  alert_email = var.alert_email
}

module "cloudsql" {
  source = "./modules/cloudsql"
  count  = { vm = 0, cloudsql = 1 }[local.config.app.database]

  config   = local.config
  networks = module.network.network_ids
}
