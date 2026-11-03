terraform {
  required_version = ">= 1.5"

  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.8"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.27.0"
    }
  }
}

locals {
  config = jsondecode(file(var.config_path))
}

provider "google" {
  project = var.project_id
  region  = local.config.project.region
  zone    = local.config.project.zone
}

provider "cloudflare" {}
