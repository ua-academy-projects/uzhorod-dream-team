resource "cloudflare_dns_record" "ui" {
  zone_id = local.cfg.cloudflare.zone_id
  name    = local.cfg.cloudflare.domain
  type    = "A"
  content = module.network.public_ips["ui"]
  proxied = true
  ttl     = 1
}

resource "cloudflare_dns_record" "www" {
  zone_id = local.cfg.cloudflare.zone_id
  name    = "www.${local.cfg.cloudflare.domain}"
  type    = "CNAME"
  content = cloudflare_dns_record.ui.name
  proxied = true
  ttl     = 1
}
