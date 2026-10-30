resource "cloudflare_dns_record" "this" {
  zone_id = var.config.cloudflare_zone_id
  name    = var.domain
  content = var.ip
  type    = "A"
  proxied = false
  ttl     = 1
}
