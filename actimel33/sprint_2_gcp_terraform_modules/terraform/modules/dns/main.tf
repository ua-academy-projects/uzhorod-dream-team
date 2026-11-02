resource "cloudflare_dns_record" "site" {
  zone_id = var.config.dns.cloudflare_zone_id
  name    = var.config.load_balancer.domain
  content = var.ip
  type    = "A"
  proxied = false
  ttl     = 1
}
