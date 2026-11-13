resource "google_compute_firewall" "rule" {
  for_each = local.rules

  name      = each.key
  network   = var.network
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = each.value.ports
  }

  source_ranges = length(each.value.source_ranges) > 0 ? each.value.source_ranges : null
  source_tags   = length(each.value.source_tags) > 0 ? each.value.source_tags : null
  target_tags   = each.value.target_tags
}
