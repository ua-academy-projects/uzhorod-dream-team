locals {
  cfg = module.config.value
}

module "config" {
  source = "./modules/config/"

  config = jsondecode(var.config_path)
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

module "vm" {
  source   = "./modules/vm"
  for_each = var.deploy_vms ? local.cfg.vm : {}

  project_id = local.cfg.google.project_id
  name       = "${local.cfg.network.name}-${each.key}"
  zone       = local.cfg.google.zone
  config     = each.value

  network = {
    subnetwork_id = module.network.subnetwork_id
    private_ip    = module.network.private_ips[each.key]
    tags          = module.network.vm_tags[each.key]
    public_access = each.value.public_ip ? {
      ip   = module.network.public_ips[each.key]
      tier = module.network.public_network_tier
    } : null
  }

  service_account = contains(keys(google_service_account.vm), each.key) ? {
    email = google_service_account.vm[each.key].email
  } : null

  startup_script = local.startup_scripts[each.key]

  depends_on = [module.network, module.registry, module.secrets]
}
