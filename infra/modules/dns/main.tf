terraform {
  required_providers {
    http = {
      source = "hashicorp/http"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5"
    }
  }
}

resource "cloudflare_dns_record" "frontend" {
  name    = var.frontend_subdomain
  zone_id = var.zone_id
  ttl     = var.ttl
  content = var.frontend_ip
  type    = "A"
  proxied = var.proxied
}
