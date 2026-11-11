module "network" {
  source = "./modules/network"
  config = local.config.network
}

module "firewall" {
  source            = "./modules/firewall"
  config            = local.config.firewall
  database_provider = local.config.database.provider
  app_backend       = local.config.compute.application.app_backend
  network_id        = module.network.network_id
  source_ranges_by_key = {
    admin = var.admin_ip_cidr == null ? [] : [var.admin_ip_cidr]
  }
}

module "secrets" {
  source = "./modules/secrets"
  config = local.config.secret_manager
}

module "compute" {
  source = "./modules/compute-instance"

  database_provider      = local.config.database.provider
  config                 = local.config.compute
  project_id             = local.config.project_id
  zone                   = local.config.zone
  region                 = local.config.region
  subnet_id              = module.network.subnet_id
  service_account_emails = module.secrets.service_account_emails

  depends_on = [
    module.network,
    module.secrets,
    module.firewall,
    module.cloud_sql,
  ]
}

module "registry" {
  source                 = "./modules/registry"
  project_id             = local.config.project_id
  region                 = local.config.region
  repository_id          = local.config.registry.repository_id
  service_account_emails = module.secrets.service_account_emails
  publishers             = var.image_publishers
}

module "iap" {
  source        = "./modules/iap"
  project_id    = local.config.project_id
  zone          = local.config.zone
  instance_name = local.config.compute.instances.bastion.name
  ssh_port      = local.config.compute.instances.bastion.startup.ssh_port
  members       = var.iap_members
  depends_on    = [module.compute]
}

module "cloud_sql" {
  source                 = "./modules/cloud-sql"
  count                  = try(local.config.cloud_sql.managed, false) ? 1 : 0
  config                 = try(local.config.cloud_sql, null)
  project_id             = local.config.project_id
  database_name          = local.config.database.name
  network_id             = module.network.network_id
  service_account_emails = module.secrets.service_account_emails
  client_services        = local.config.database.provider == "cloud_sql" ? toset(["fetcher", "history"]) : toset([])
}

module "monitoring" {
  source                 = "./modules/monitoring"
  count                  = try(local.config.monitoring.enabled, false) ? 1 : 0
  project_id             = local.config.project_id
  config                 = local.config.monitoring
  instance_ids           = module.compute.numeric_instance_ids
  service_account_emails = { for key, email in module.secrets.service_account_emails : key => email if contains(keys(module.compute.instance_ids), key) && key != "bastion" }
  sql_instance_name      = try(local.config.cloud_sql.managed, false) ? local.config.cloud_sql.instance_name : null
  ui_host                = module.compute.public_ips["ui"]
}
