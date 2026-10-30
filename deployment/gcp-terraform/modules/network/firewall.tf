locals {
  vm_tags = { for name, vm in var.vms : name => vm.tags }
}

resource "google_compute_firewall" "ingress" {
  for_each = var.config.firewall_rules

  project   = var.google.project_id
  name      = "${var.config.name}-${each.key}"
  network   = google_compute_network.main.id
  direction = "INGRESS"

  source_ranges = length(each.value.source_ranges) > 0 ? sort(tolist(each.value.source_ranges)) : null
  source_tags   = length(each.value.source_tags) > 0 ? sort(tolist(each.value.source_tags)) : null
  target_tags   = sort(tolist(each.value.target_tags))

  allow {
    protocol = "tcp"
    ports    = sort([for port in each.value.ports : tostring(port)])
  }
}
