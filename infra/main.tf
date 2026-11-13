terraform {
  required_providers {
    http = {
      source = "hashicorp/http"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5"
    }
  }

  # bucket comes from backend.hcl (written by bootstrap): terraform init -backend-config=backend.hcl
  backend "gcs" {
    prefix = "state/terraform.tfstate"
  }
}

locals {
  config = jsondecode(file("${path.module}/${var.config_path}"))

  # address of whoever runs terraform; "MY_IP" in ssh.bastion_from stands for it
  my_ip = "${chomp(data.http.my_ip.response_body)}/32"
}

data "http" "my_ip" {
  url = "https://api.ipify.org"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 && can(cidrhost("${chomp(self.response_body)}/32", 0))
      error_message = "could not detect the public IP (api.ipify.org returned an unexpected answer)."
    }
  }
}

# Cloudflare's own published list of the addresses its proxy connects from. Without it a proxied record cannot reach a firewalled origin.
data "http" "cloudflare_ips" {
  url = "https://www.cloudflare.com/ips-v4"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 && alltrue([for r in split("\n", chomp(self.response_body)) : can(cidrhost(r, 0))])
      error_message = "could not read the Cloudflare IPv4 ranges (www.cloudflare.com/ips-v4 returned an unexpected answer)."
    }
  }
}

data "cloudflare_zone" "frontend" {
  filter = {
    name = local.config.dns.frontend_domain
  }
}

provider "google" {
  project = local.config.project_id
  region  = local.config.region
  zone    = local.config.zone
}

provider "cloudflare" {
  api_token = var.cloudflare_token
}

module "network" {
  source      = "./modules/network"
  name        = local.config.network.name
  region      = local.config.region
  subnets     = local.config.network.subnets
  nat_enabled = local.config.network.nat.enabled
}

module "firewall" {
  source            = "./modules/firewall"
  network           = module.network.vpc_name
  my_ip             = local.my_ip
  cloudflare_ranges = split("\n", chomp(data.http.cloudflare_ips.response_body))
  ssh               = local.config.ssh
  services          = local.config.services
  instances         = local.config.instances
}

module "iam" {
  source          = "./modules/iam"
  project_id      = local.config.project_id
  region          = local.config.region
  instances       = local.config.instances
  operator_member = var.operator_member
}

module "instances" {
  source                 = "./modules/instances"
  project_id             = local.config.project_id
  region                 = local.config.region
  defaults               = local.config.defaults
  subnet_ids             = module.network.subnet_ids
  instances              = local.config.instances
  service_account_emails = module.iam.vm_emails
}

module "ops_agent" {
  source     = "./modules/ops_agent"
  project_id = local.config.project_id
  zones = toset([
    for v in values(local.config.instances) : coalesce(try(v.zone, null), local.config.defaults.zone)
  ])
  nginx_zones = toset([
    for v in values(local.config.instances) : coalesce(try(v.zone, null), local.config.defaults.zone)
    if try(v.labels.ops_agent, "") == "nginx"
  ])
  domain     = local.config.services.frontend.domain
  monitoring = local.config.monitoring
}

module "cloudsql" {
  source              = "./modules/cloudsql"
  network_id          = module.network.vpc_id
  region              = local.config.region
  zone                = local.config.cloudsql.zone
  name                = local.config.cloudsql.name
  private_range       = local.config.cloudsql.private_range
  database_version    = local.config.cloudsql.database_version
  tier                = local.config.cloudsql.tier
  edition             = local.config.cloudsql.edition
  availability_type   = local.config.cloudsql.availability_type
  disk_size_gb        = local.config.cloudsql.disk_size_gb
  deletion_protection = local.config.cloudsql.deletion_protection
  backup              = local.config.cloudsql.backup
  databases           = local.config.cloudsql.databases

  passwords = {
    history = var.history_pass
  }
}

module "dns" {
  source             = "./modules/dns"
  zone_id            = data.cloudflare_zone.frontend.zone_id
  ttl                = local.config.dns.ttl
  frontend_subdomain = local.config.dns.frontend_subdomain
  frontend_ip        = try(module.instances.external_ips["frontend"], null)
  proxied            = local.config.dns.proxied
}
