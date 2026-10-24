resource "google_compute_network" "analyzer" {
  name                    = "analyzer-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "analyzer" {
  name          = "analyzer-subnet"
  ip_cidr_range = "10.10.0.0/24"
  region        = var.region
  network       = google_compute_network.analyzer.id
}

resource "google_compute_router" "analyzer" {
  name    = "analyzer-router"
  region  = var.region
  network = google_compute_network.analyzer.id
}

resource "google_compute_router_nat" "analyzer" {
  name                               = "analyzer-nat"
  router                             = google_compute_router.analyzer.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}
