terraform {
  backend "gcs" {
    bucket = "project-a5588ddc-4a2e-4c04-879-tfstate"
    prefix = "datamonitor/dev"
  }

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
  source = "./modules/firewall"
  config = {
    rules = [for rule in local.config.firewall.rules : merge(rule, {
      enabled = (
        rule.name == "allow-app-postgres" ? local.config.database.provider == "container" :
        contains(["allow-app-rabbitmq", "allow-ui-redis"], rule.name) ? local.config.compute.application.app_backend == "hybrid" : true
      )
    })]
  }
  network_id = module.network.network_id
  source_ranges_by_key = {
    admin = var.admin_ip_cidr == null ? [] : [var.admin_ip_cidr]
  }
}

module "secrets" {
  source = "./modules/secrets"
  config = local.config.secret_manager
}

module "compute" {
  source = "./modules/compute-instance"

  database = {
    provider        = local.config.database.provider
    host            = local.config.compute.instances.postgres.network_ip
    name            = local.config.database.name
    connection_name = local.config.database.provider == "cloud_sql" ? "${local.config.project_id}:${local.config.cloud_sql.region}:${local.config.cloud_sql.instance_name}" : ""
  }
  config                 = local.config.compute
  project_id             = local.config.project_id
  zone                   = local.config.zone
  region                 = local.config.region
  subnet_id              = module.network.subnet_id
  service_account_emails = module.secrets.service_account_emails
  env_secret_ids         = module.secrets.env_secret_ids

  depends_on = [
    module.network,
    module.secrets,
    module.firewall,
    google_project_iam_member.cloud_sql_client,
  ]
}

resource "google_project_iam_member" "cloud_sql_client" {
  for_each = local.config.database.provider == "cloud_sql" ? toset(["fetcher", "history"]) : toset([])
  project  = local.config.project_id
  role     = "roles/cloudsql.client"
  member   = "serviceAccount:${module.secrets.service_account_emails[each.key]}"
}
