module "network" {
  source            = "../../modules/network"
  config            = jsondecode(file("${path.module}/../../config.json"))
  ssh_allowed_cidrs = ["${var.my_ip}/32"]
}

module "cloudsql" {
  source = "../../modules/cloudsql"
  count  = jsondecode(file("${path.module}/../../config.json")).database.type == "cloudsql" ? 1 : 0

  config     = jsondecode(file("${path.module}/../../config.json"))
  network_id = module.network.network_id
}

module "service_accounts" {
  source     = "../../modules/service_accounts"
  config     = jsondecode(file("${path.module}/../../config.json"))
  project_id = var.project_id
}

module "vm" {
  source   = "../../modules/vm"
  for_each = module.service_accounts.vms

  config          = jsondecode(file("${path.module}/../../config.json"))
  name            = each.key
  services        = each.value.services
  subnetwork_id   = module.network.subnetwork_id
  bastion_tag     = module.network.bastion_tag
  service_account = module.service_accounts.emails[each.key]

  depends_on = [module.network]
}

module "secrets" {
  source  = "../../modules/secrets"
  config  = jsondecode(file("${path.module}/../../config.json"))
  vms     = module.service_accounts.vms
  members = module.service_accounts.members
}