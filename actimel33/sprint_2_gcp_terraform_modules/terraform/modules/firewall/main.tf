locals {
  rules = merge(var.config.firewall.common, var.config.firewall[var.config.app.backend], lookup(var.config.firewall, var.config.app.database, {}))
}

resource "google_compute_firewall" "rule" {
  for_each = local.rules

  name      = each.key
  network   = var.network
  direction = "INGRESS"

  allow {
    protocol = each.value.protocol
    ports    = each.value.ports
  }

  source_ranges = each.value.source_ranges
  source_tags   = each.value.source_tags
  target_tags   = each.value.target_tags
}
