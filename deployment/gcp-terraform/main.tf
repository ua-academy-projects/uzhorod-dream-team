locals {
  cfg = jsondecode(file(var.config_path))
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

module "cloud_sql" {
  source = "./modules/cloud-sql"
  count  = local.cfg.modes.cloud_sql ? 1 : 0

  cfg              = local.cfg
  network          = module.network
  service_accounts = google_service_account.vm
  secrets          = module.secrets
  revisions        = var.secret_revisions
}

module "vm" {
  source = "./modules/vm"

  cfg              = local.cfg
  service_accounts = google_service_account.vm
  network          = module.network
}
