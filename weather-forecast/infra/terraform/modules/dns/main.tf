data "cloudflare_zone" "site" {
  filter = {
    name = var.config.app.public.dns_zone
  }
}

resource "cloudflare_dns_record" "site" {
  zone_id = data.cloudflare_zone.site.zone_id
  name    = var.config.app.public.domain
  type    = "A"
  content = var.external_ips[var.config.app.public.host]
  proxied = false
  ttl     = 300
}
