terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  backend "gcs" {}
}

provider "google" {
  project = local.cfg.project.id
  region  = local.cfg.project.region
  zone    = local.cfg.project.zone

  default_labels = {
    app = "${local.cfg.project.name_prefix}-tracker"
  }
}
