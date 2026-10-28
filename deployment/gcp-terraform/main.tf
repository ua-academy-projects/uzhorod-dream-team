locals {
  cfg = module.config.value
}

module "config" {
  source = "./modules/config/"

  config = jsondecode(file("${path.module}/../config/deployment.json"))
}

module "network" {
  source = "./modules/network/"

  project_id = local.cfg.google.project_id
  region     = local.cfg.google.region
  config     = local.cfg.network
  vms        = local.cfg.vm

  depends_on = [google_project_service.required["compute"]]
}

module "registry" {
  source = "./modules/registry/"

  repository_id = local.cfg.registry.repository_id
  location      = local.cfg.google.region
  project_id    = local.cfg.google.project_id
  readers = {
    for name, acc in google_service_account.vm :
    name => "serviceAccount:${acc.email}"
  }

  depends_on = [google_project_service.required["registry"]]
}
