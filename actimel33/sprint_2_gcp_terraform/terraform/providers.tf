provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone

  default_labels = {
    app        = "crypto-price-service"
    managed-by = "terraform"
  }
}

# The Cloudflare token lives in Secret Manager.
ephemeral "google_secret_manager_secret_version" "cloudflare_token" {
  secret = var.cloudflare_token_secret
}

provider "cloudflare" {
  api_token = ephemeral.google_secret_manager_secret_version.cloudflare_token.secret_data
}
