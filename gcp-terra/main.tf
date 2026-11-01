terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "6.8.0"
    }
  }
}

provider "google" {
  project = local.config.project_id
  region  = local.config.region
  zone    = local.config.zone
}


locals {
  config = jsondecode(file("${path.root}/../config.json"))
}

module "network" {
  source = "./modules/network"
  config = local.config.network
}

module "firewall" {
  source     = "./modules/firewall"
  config     = local.config.firewall
  network_id = module.network.network_id
  source_ranges_by_key = {
    admin = [var.admin_ip_cidr]
  }
}

module "secrets" {
  source = "./modules/secrets"
  config = local.config.secret_manager
}

module "compute" {
  source = "./modules/compute-instance"

  config                = local.config.compute
  project_id            = local.config.project_id
  zone                  = local.config.zone
  region                = local.config.region
  subnet_id             = module.network.subnet_id
  service_account_email = module.secrets.service_account_email

  depends_on = [
    module.network,
    module.secrets,
    module.firewall,
  ]
}