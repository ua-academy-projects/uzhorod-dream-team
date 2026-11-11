# Read the shared configuration once; modules select and process their own fields.
locals {
  config = jsondecode(file("${path.root}/../config.json"))
}

terraform {
  backend "gcs" {}

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
