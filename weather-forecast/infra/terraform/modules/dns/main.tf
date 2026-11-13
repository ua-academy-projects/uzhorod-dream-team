data "cloudflare_zone" "site" {
  filter = {
    name = var.config.app.public.dns_zone
  }
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "site" {
  account_id = data.cloudflare_zone.site.account.id
  name       = "${var.config.project.prefix}-site"
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "site" {
  account_id = data.cloudflare_zone.site.account.id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.site.id

  config = {
    ingress = [
      {
        hostname = var.config.app.public.domain
        service  = "https://localhost:443"
        origin_request = {
          origin_server_name = var.config.app.public.domain
        }
      },
      {
        service = "http_status:404"
      },
    ]
  }
}

resource "cloudflare_dns_record" "site" {
  zone_id = data.cloudflare_zone.site.zone_id
  name    = var.config.app.public.domain
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.site.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}
