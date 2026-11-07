locals {
  config = jsondecode(file("${path.module}/../../config.json"))
  labels = { app = local.config.prefix, env = "dev", managed-by = "terraform" }
}

module "network" {
  source            = "../../modules/network"
  config            = local.config
  ssh_allowed_cidrs = ["${var.my_ip}/32"]
}

module "cloudsql" {
  source     = "../../modules/cloudsql"
  config     = local.config
  network_id = module.network.network_id
  labels     = local.labels
}

module "service_accounts" {
  source     = "../../modules/service_accounts"
  config     = local.config
  project_id = var.project_id
}

module "vm" {
  source   = "../../modules/vm"
  for_each = local.config.vms

  config          = local.config
  name            = each.key
  subnetwork_id   = module.network.subnetwork_id
  bastion_tag     = module.network.bastion_tag
  service_account = module.service_accounts.emails[each.key]
  labels          = local.labels

  depends_on = [module.network]
}

module "secrets" {
  source  = "../../modules/secrets"
  config  = local.config
  members = module.service_accounts.members
  labels  = local.labels
}
