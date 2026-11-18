module "network" {
  source            = "../../modules/network"
  config            = jsondecode(file("${path.module}/../../config.json"))
  ssh_allowed_cidrs = ["${var.my_ip}/32"]
}

module "vm" {
  source   = "../../modules/vm"
  config   = jsondecode(file("${path.module}/../../config.json"))
  networks = module.network.by_cloud

  depends_on = [module.network]
}

module "secrets" {
  source = "../../modules/secrets"
  config = jsondecode(file("${path.module}/../../config.json"))
  vms    = module.vm.vms
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