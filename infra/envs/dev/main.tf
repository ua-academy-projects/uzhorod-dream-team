module "network" {
  source            = "../../modules/network"
  config            = jsondecode(file("${path.module}/../../config.json"))
  ssh_allowed_cidrs = ["${var.my_ip}/32"]
  aws_account_id    = var.aws_account_id
}

module "secrets" {
  source = "../../modules/secrets"
  config = jsondecode(file("${path.module}/../../config.json"))
}

module "bastion" {
  source   = "../../modules/bastion"
  config   = jsondecode(file("${path.module}/../../config.json"))
  networks = module.network.by_cloud
  secrets  = module.secrets.by_cloud

  depends_on = [module.network]
}

module "vm" {
  source    = "../../modules/vm"
  config    = jsondecode(file("${path.module}/../../config.json"))
  instances = jsondecode(file("${path.module}/../../config.json")).vms.instances
  networks  = module.network.by_cloud
  secrets   = module.secrets.by_cloud
  bastions  = module.bastion.by_cloud

  depends_on = [module.network, module.bastion]
}

module "database" {
  source   = "../../modules/database"
  config   = jsondecode(file("${path.module}/../../config.json"))
  networks = module.network.by_cloud
}

module "monitoring" {
  source = "../../modules/monitoring"
  config = jsondecode(file("${path.module}/../../config.json"))
}
