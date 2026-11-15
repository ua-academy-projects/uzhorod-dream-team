module "network" {
  source = "./modules/network"
  config = local.config
}

module "firewall" {
  source     = "./modules/firewall"
  config     = local.config
  network_id = module.network.network_id
}

module "secrets" {
  source = "./modules/secrets"
  config = local.config
}

module "compute" {
  source                 = "./modules/compute-instance"
  config                 = local.config
  subnet_id              = module.network.subnet_id
  service_account_emails = module.secrets.service_account_emails
  depends_on             = [module.firewall]
}

module "registry" {
  source                 = "./modules/registry"
  config                 = local.config
  service_account_emails = module.secrets.service_account_emails
  publishers             = var.image_publishers
}

module "iap" {
  source     = "./modules/iap"
  config     = local.config
  members    = var.iap_members
  depends_on = [module.compute]
}

module "cloud_sql" {
  source                 = "./modules/cloud-sql"
  config                 = local.config
  network_id             = module.network.network_id
  service_account_emails = module.secrets.service_account_emails
}

module "monitoring" {
  source                 = "./modules/monitoring"
  monitoring             = local.monitoring
  config                 = local.config
  instance_ids           = module.compute.numeric_instance_ids
  service_account_emails = module.secrets.service_account_emails
  public_ips             = module.compute.public_ips
}
