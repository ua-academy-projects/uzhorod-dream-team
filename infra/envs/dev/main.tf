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

module "vm" {
  source   = "../../modules/vm"
  config   = jsondecode(file("${path.module}/../../config.json"))
  networks = module.network.by_cloud
  secrets  = module.secrets.by_cloud

  depends_on = [module.network]
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
