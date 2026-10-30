provider "google" {
  project = local.config.project.id
  region  = local.config.project.region
}

# The API token is read from the CLOUDFLARE_API_TOKEN environment variable, never from files.
provider "cloudflare" {}
