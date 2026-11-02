module "network" {
  source = "./modules/network"

  config = local.config
}

module "firewall" {
  source = "./modules/firewall"

  config     = local.config
  my_ip_cidr = var.my_ip_cidr
  networks   = module.network.networks
}

module "service_accounts" {
  source = "./modules/service_accounts"

  config     = local.config
  project_id = var.project_id
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

  config       = local.config
  external_ips = module.vms.external_ips
}
