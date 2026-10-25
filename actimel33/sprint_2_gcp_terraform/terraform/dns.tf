# The domain's DNS lives in Cloudflare.
resource "cloudflare_dns_record" "ui" {
  zone_id = var.cloudflare_zone_id
  name    = var.domain
  type    = "A"
  content = google_compute_global_address.ui.address
  ttl     = 300
  proxied = false
  comment = "crypto-price-service, managed by Terraform"
}
