
resource "google_compute_firewall" "rules" {
  for_each  = { for rule in var.config.rules : rule.name => rule }
  name      = each.value.name
  network   = var.network_id
  direction = each.value.direction
  priority  = each.value.priority

  source_ranges      = each.value.source_ranges_key == null ? each.value.source_ranges : var.source_ranges_by_key[each.value.source_ranges_key]
  destination_ranges = each.value.destination_ranges
  target_tags        = each.value.target_tags

  dynamic "allow" {
    for_each = each.value.allowed
    content {
      protocol = allow.value.protocol
      ports    = allow.value.ports
    }
  }
  dynamic "deny" {
    for_each = each.value.denied
    content {
      protocol = deny.value.protocol
      ports    = deny.value.ports
    }
  }
}

