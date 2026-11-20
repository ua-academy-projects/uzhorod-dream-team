locals {
  clouds = keys(var.networks)
  secrets = ["ssh-host-key"]
  bastion = merge(var.config.vms.bastion, { bastion = true, secrets = local.secrets })
}

module "gcp" {
  source = "../vm"
  count  = contains(local.clouds, "gcp") ? 1 : 0

  config    = var.config
  instances = { bastion = merge(local.bastion, { cloud = "gcp" }) }
  networks  = var.networks
  secrets   = var.secrets
}

module "aws" {
  source = "../vm"
  count  = contains(local.clouds, "aws") ? 1 : 0

  config    = var.config
  instances = { bastion = merge(local.bastion, { cloud = "aws" }) }
  networks  = var.networks
  secrets   = var.secrets
}
