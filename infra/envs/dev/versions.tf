terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }

  #   terraform init -backend-config="bucket=$TF_STATE_BUCKET"
  backend "gcs" {
    prefix = "citybikes/dev"
  }
}

provider "google" {
  project = var.project_id
  region  = local.config.location.region
  zone    = local.config.location.zone
}
