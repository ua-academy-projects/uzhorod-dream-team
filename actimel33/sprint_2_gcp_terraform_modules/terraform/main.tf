locals {
  config = jsondecode(file("${path.module}/../../terraform_resources_configuration/config.json"))
}

module "network" {
  source = "./modules/network"

  config = local.config
}

module "firewall" {
  source = "./modules/firewall"

  config = local.config

  network = module.network.self_link
}

module "artifact_registry" {
  source = "./modules/artifact_registry"

  config = local.config
}

module "service_accounts" {
  source = "./modules/service_accounts"

  config = local.config
}

module "vms" {
  source = "./modules/vms"

  config = local.config

  subnets          = module.network.subnets
  registry         = module.artifact_registry.repository
  service_accounts = module.service_accounts.vm_emails
}

module "secrets" {
  source = "./modules/secrets"

  config = local.config

  readers = module.service_accounts.vm_emails
}

module "cloud_sql" {
  source = "./modules/cloud_sql"
  count  = local.config.app.database == "cloud_sql" ? 1 : 0

  config = local.config

  network         = module.network.self_link
  subnets         = module.network.subnets
  secret_versions = module.secrets.versions
}

module "load_balancer" {
  source = "./modules/load_balancer"

  config = local.config

  instances = module.vms.instances
}

module "dns" {
  source = "./modules/dns"

  config = local.config

  ip = module.load_balancer.ip
}

module "monitoring" {
  source = "./modules/monitoring"

  config = local.config

  https_rule = module.load_balancer.https_rule_name
}
