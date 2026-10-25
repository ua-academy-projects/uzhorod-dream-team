# Two VPCs, as in the Vagrant setup: every NIC of a VM sits in its own network.
resource "google_compute_network" "private" {
  name                    = "crypto-private"
  auto_create_subnetworks = false

  depends_on = [google_project_service.this]
}

resource "google_compute_network" "edge" {
  name                    = "crypto-edge"
  auto_create_subnetworks = false

  depends_on = [google_project_service.this]
}

resource "google_compute_subnetwork" "private" {
  name          = "private"
  network       = google_compute_network.private.id
  ip_cidr_range = local.private_cidr
  # Google APIs (Secret Manager) without an external IP.
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_subnetwork" "edge" {
  name          = "edge"
  network       = google_compute_network.edge.id
  ip_cidr_range = local.edge_cidr
  # The ui VM has no external IP: images and secrets come over Google's network.
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Outbound internet for the VMs without an external IP (apt, images, CoinGecko),
# one NAT per network. Inbound nothing: only the bastion has a public address.
locals {
  nat_networks = {
    private = google_compute_network.private.id
    edge    = google_compute_network.edge.id
  }
}

resource "google_compute_router" "nat" {
  for_each = local.nat_networks

  name    = "crypto-router-${each.key}"
  network = each.value
}

resource "google_compute_router_nat" "nat" {
  for_each = local.nat_networks

  name                               = "crypto-nat-${each.key}"
  router                             = google_compute_router.nat[each.key].name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
