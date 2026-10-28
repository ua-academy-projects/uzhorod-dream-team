locals {
  cfg = module.config.value
}

module "config" {
  source = "./modules/config/"

  config = jsondecode(file("${path.module}/../config/deployment.json"))
}

module "registry" {
  source = "./modules/registry/"

  location   = local.cfg.google.region
  project_id = local.cfg.google.project_id
  readers = {
    for name, acc in google_service_account.vm :
    name => "serviceAccount:${acc.email}"
  }

  depends_on = [google_project_service.required["registry"]]
}
