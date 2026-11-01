locals {
  bootstrap = jsondecode(file(pathexpand(var.bootstrap_config_path)))
  cfg       = merge(jsondecode(file(var.config_path)), { google = local.bootstrap.google })
}

module "network" {
  source = "./modules/network/"

  cfg = local.cfg
}

module "registry" {
  source = "./modules/registry/"

  cfg     = local.cfg
  readers = google_service_account.vm
}

module "secrets" {
  source = "./modules/secrets/"

  cfg              = local.cfg
  service_accounts = google_service_account.vm
  revisions        = var.secret_revisions
  payloads         = var.secret_payloads
}

module "vm" {
  source = "./modules/vm"

  cfg              = local.cfg
  service_accounts = google_service_account.vm
  network          = module.network
  registry         = module.registry
  secrets          = module.secrets

  depends_on = [module.network, module.registry, module.secrets]
}
