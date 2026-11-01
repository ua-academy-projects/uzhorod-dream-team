resource "google_compute_network" "analyzer" {
  name                    = var.config.name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "analyzer" {
  name          = var.config.subnet.name
  ip_cidr_range = var.config.subnet.cidr
  region        = var.config.subnet.region
  network       = google_compute_network.analyzer.id
}
resource "google_compute_router" "analyzer" {
  count = var.config.nat.enabled ? 1 : 0

  name    = "${var.config.name}-router"
  region  = var.config.subnet.region
  network = google_compute_network.analyzer.id
}

resource "google_compute_router_nat" "analyzer" {
  count = var.config.nat.enabled ? 1 : 0

  name                               = var.config.nat.name
  router                             = google_compute_router.analyzer[0].name
  region                             = var.config.subnet.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}
