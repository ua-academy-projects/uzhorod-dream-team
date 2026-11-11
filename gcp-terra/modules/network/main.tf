locals {
  config = var.config.network
}

resource "google_compute_network" "analyzer" {
  name                    = local.config.name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "analyzer" {
  name          = local.config.subnet.name
  ip_cidr_range = local.config.subnet.cidr
  region        = local.config.subnet.region
  network       = google_compute_network.analyzer.id
}
resource "google_compute_router" "analyzer" {
  count = local.config.nat.enabled ? 1 : 0

  name    = "${local.config.name}-router"
  region  = local.config.subnet.region
  network = google_compute_network.analyzer.id
}

resource "google_compute_router_nat" "analyzer" {
  count = local.config.nat.enabled ? 1 : 0

  name                               = local.config.nat.name
  router                             = google_compute_router.analyzer[0].name
  region                             = local.config.subnet.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}
