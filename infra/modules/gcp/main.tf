# The whole GCP stack. modules/layout says which VMs exist and what runs on them;
# here they are built, in order: network -> accounts -> VMs -> secrets -> database -> monitoring.

module "network" {
  source            = "./network"
  config            = var.config
  ssh_allowed_cidrs = var.ssh_allowed_cidrs
}

module "iam" {
  source     = "./iam"
  project_id = var.project_id
  config     = var.config
  vms        = var.vms
}

module "vm" {
  source   = "./vm"
  for_each = var.vms

  config          = var.config
  name            = each.key
  vm              = each.value
  subnetwork_id   = module.network.subnetwork_id
  bastion_tag     = module.network.bastion_tag
  service_account = module.iam.emails[each.key]

  depends_on = [module.network]
}

module "secrets" {
  source  = "./secrets"
  config  = var.config
  vms     = var.vms
  members = module.iam.members
}

module "database" {
  source = "./database"
  count  = var.config.database.type == "managed" ? 1 : 0

  config     = var.config
  network_id = module.network.network_id
}

module "monitoring" {
  source     = "./monitoring"
  config     = var.config
  project_id = var.project_id
}
