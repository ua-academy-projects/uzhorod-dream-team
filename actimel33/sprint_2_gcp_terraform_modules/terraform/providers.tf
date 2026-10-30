provider "google" {
  project                     = local.config.project_id
  region                      = local.config.region
  impersonate_service_account = local.terraform_service_account_email
}

# The API token is read from the CLOUDFLARE_API_TOKEN environment variable, never from files.
provider "cloudflare" {}
