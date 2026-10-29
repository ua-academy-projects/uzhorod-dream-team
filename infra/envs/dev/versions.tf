terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # terraform init -backend-config=backend.hcl
  backend "gcs" {
    prefix = "citybikes/dev"
  }
}

provider "google" {
  project = local.project.id
  region  = local.project.region
  zone    = local.project.zone
}
