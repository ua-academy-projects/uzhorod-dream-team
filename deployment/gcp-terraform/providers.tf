terraform {
  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9.1"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 8.9.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.28.1"
    }
  }
}

provider "google" {
  project = local.cfg.google.project_id
  region  = local.cfg.google.region
  zone    = local.cfg.google.zone
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
  ephemeral = true
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
