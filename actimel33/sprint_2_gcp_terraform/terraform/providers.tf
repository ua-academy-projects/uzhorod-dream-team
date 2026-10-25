provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone

  default_labels = {
    app        = "crypto-price-service"
    managed-by = "terraform"
  }
}

# The token comes from the CLOUDFLARE_API_TOKEN environment variable, never from code.
provider "cloudflare" {}
