terraform {
  required_version = ">= 1.15.0, < 2.0.0"

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
  }
}
