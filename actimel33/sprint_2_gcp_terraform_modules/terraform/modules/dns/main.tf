resource "cloudflare_dns_record" "this" {
  zone_id = var.cloudflare_zone_id
  name    = var.record_name
  content = var.lb_ip_address
  type    = "A"
  proxied = false
  ttl     = 1
}
