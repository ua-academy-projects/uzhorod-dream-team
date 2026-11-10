resource "google_compute_network" "vpc" {
  for_each = var.config.networks

  name                    = "${var.config.project.prefix}-${each.key}"
  auto_create_subnetworks = false
  mtu                     = lookup(each.value, "mtu", 1460)
}

resource "google_compute_subnetwork" "subnet" {
  for_each = var.config.subnets

  name          = "${var.config.project.prefix}-${each.key}"
  network       = google_compute_network.vpc[each.value.network].id
  ip_cidr_range = each.value.cidr
}
