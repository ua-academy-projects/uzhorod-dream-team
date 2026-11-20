terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }

    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }

  #   terraform init -backend-config="bucket=$TF_STATE_BUCKET"
  backend "gcs" {
    prefix = "citybikes/dev"
  }
}

provider "google" {
  project = var.project_id
}

provider "aws" {
  region              = jsondecode(file("${path.module}/../../config.json")).clouds.aws.location.regions[jsondecode(file("${path.module}/../../config.json")).region]
  allowed_account_ids = var.aws_account_id != "" ? [var.aws_account_id] : null

  access_key                  = var.aws_account_id != "" ? null : "aws-not-set-up"
  secret_key                  = var.aws_account_id != "" ? null : "aws-not-set-up"
  skip_credentials_validation = var.aws_account_id == ""
  skip_requesting_account_id  = var.aws_account_id == ""
  skip_metadata_api_check     = var.aws_account_id == ""
}
