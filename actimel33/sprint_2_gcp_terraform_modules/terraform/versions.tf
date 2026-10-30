terraform {
  required_version = ">= 1.15.0, < 2.0.0"

  # bucket, prefix and the account come from backend.hcl written by bootstrap/bootstrap.sh.
  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.8"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.28"
    }
  }
}
