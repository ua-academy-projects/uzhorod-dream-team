provider "google" {
  project = local.config.project_id
  region  = local.config.region
}

# The API token is read from the CLOUDFLARE_API_TOKEN environment variable, never from files.
provider "cloudflare" {}
