provider "google" {
  project = local.config.project.id
  region  = local.config.project.region
}

provider "cloudflare" {}
