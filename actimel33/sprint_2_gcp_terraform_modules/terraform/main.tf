locals {
  config = jsondecode(file("${path.module}/../../terraform_resources_configuration/config.json"))
}

module "network" {
  source = "./modules/network"

  config = local.config.network
  region = local.config.project.region
}

module "firewall" {
  source = "./modules/firewall"

  config  = local.config.firewall
  backend = local.config.app.backend
  network = module.network.self_link
}

module "artifact_registry" {
  source = "./modules/artifact_registry"

  config  = local.config.registry
  project = local.config.project
}

module "vms" {
  source = "./modules/vms"

  config   = local.config.vms
  project  = local.config.project
  backend  = local.config.app.backend
  subnets  = module.network.subnets
  registry = module.artifact_registry.repository
}

module "secrets" {
  source = "./modules/secrets"

  config  = local.config.secrets
  readers = module.vms.service_account_emails
}

module "load_balancer" {
  source = "./modules/load_balancer"

  config    = local.config.load_balancer
  instances = module.vms.instances
}

module "dns" {
  source = "./modules/dns"

  config = local.config.dns
  domain = module.load_balancer.domain
  ip     = module.load_balancer.ip
}

module "ssh_config" {
  source = "./modules/ssh_config"

  config    = local.config.ssh
  project   = local.config.project
  instances = module.vms.instances
}
