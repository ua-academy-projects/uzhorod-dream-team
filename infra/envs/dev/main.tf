locals {
  config = jsondecode(file("${path.module}/../../config.json"))
  prefix = local.config.prefix
  labels = { app = local.prefix, env = "dev", managed-by = "terraform" }
}

module "network" {
  source = "../../modules/network"
  config = merge(local.config.network, {
    name              = "${local.prefix}-vpc"
    region            = var.region
    ssh_allowed_cidrs = ["${var.my_ip}/32"]
    bastion_tag       = "bastion"
  })
}

module "cloudsql" {
  source = "../../modules/cloudsql"
  config = merge(local.config.database, {
    name       = "${local.prefix}-pg"
    region     = var.region
    zone       = var.zone
    network_id = module.network.network_id
    database   = local.config.app.db_name
    labels     = local.labels
  })
}

module "service_accounts" {
  source = "../../modules/service-accounts"
  config = {
    project_id = var.project_id
    prefix     = local.prefix
    vms        = local.config.vms
  }
}

module "vm" {
  source   = "../../modules/vm"
  for_each = local.config.vms

  config = merge(each.value, {
    name            = "${local.prefix}-${each.key}"
    service_account = module.service_accounts.emails[each.key]
    region          = var.region
    zone            = var.zone
    subnetwork_id   = module.network.subnetwork_id
    subnet_cidr     = local.config.network.subnet_cidr
    bastion_tag     = "bastion"
    labels          = merge(local.labels, { vm = each.key })
    ssh             = local.config.ssh
  })

  depends_on = [module.network]
}

module "secrets" {
  source = "../../modules/secrets"
  config = {
    prefix  = local.prefix
    vms     = local.config.vms
    members = module.service_accounts.members
    labels  = local.labels
  }
}
