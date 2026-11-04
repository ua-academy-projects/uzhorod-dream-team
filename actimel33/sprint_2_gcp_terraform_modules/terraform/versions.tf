terraform {
  required_version = ">= 1.15.0, < 2.0.0"

  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.8"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.28"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
  }
}
