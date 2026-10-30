locals {
  cfg             = jsondecode(file(var.config_path))
}

module "network" {
  source = "./modules/network/"

  google = local.cfg.google
  config = local.cfg.network
  vms    = local.cfg.vm

  depends_on = [google_project_service.required["compute"]]
}

module "registry" {
  source = "./modules/registry/"

  repository = merge(local.cfg.registry, { location = local.cfg.google.region })
  project_id = local.cfg.google.project_id
  readers    = google_service_account.vm

  depends_on = [google_project_service.required["registry"]]
}

module "secrets" {
  source = "./modules/secrets/"

  project_id       = local.cfg.google.project_id
  config           = local.cfg.secrets
  vms              = local.cfg.vm
  service_accounts = google_service_account.vm
  revisions        = var.secret_revisions
  payloads         = var.secret_payloads

  depends_on = [google_project_service.required["secret"]]
}

module "vm" {
  source   = "./modules/vm"
  for_each = { for name, vm in local.cfg.vm : name => vm if local.cfg.deploy_vms }

  name_prefix = local.cfg.vm_name_prefix
  google = merge(local.cfg.google, {
    service_account = lookup(google_service_account.vm, each.key, null),
  })
  network = merge(each.value, local.cfg.network, module.network)
  machine = merge(each.value, {
    name = each.key,
  })
  application  = local.cfg.application
  images       = local.cfg.images
  domain       = local.cfg.cloudflare.domain
  registry_url = module.registry.repository_url
  secrets      = merge(local.cfg.secrets, module.secrets)
  vms          = local.cfg.vm

  depends_on = [module.network, module.registry, module.secrets]
}
