resource "google_compute_firewall" "external" {
  for_each = var.config.firewall.external

  name          = "${var.config.project.prefix}-ext-${each.key}"
  network       = var.networks[each.value.network]
  source_ranges = each.value.source_ranges
  target_tags   = each.value.to

  allow {
    protocol = lookup(each.value, "protocol", "tcp")
    ports    = lookup(each.value, "ports", [])
  }
}

resource "google_compute_firewall" "internal" {
  for_each = var.config.firewall.internal

  name        = "${var.config.project.prefix}-int-${each.key}"
  network     = var.networks[each.value.network]
  source_tags = each.value.from
  target_tags = each.value.to

  allow {
    protocol = lookup(each.value, "protocol", "tcp")
    ports    = lookup(each.value, "ports", [])
  }
}
