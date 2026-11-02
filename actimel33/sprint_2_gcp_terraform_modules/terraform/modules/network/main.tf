resource "google_compute_network" "vpc" {
  name                    = var.config.network.vpc
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "management" {
  name          = var.config.network.subnets.management.name
  ip_cidr_range = var.config.network.subnets.management.cidr
  network       = google_compute_network.vpc.id
  region        = var.config.project.region
}

resource "google_compute_subnetwork" "private" {
  name          = var.config.network.subnets.private.name
  ip_cidr_range = var.config.network.subnets.private.cidr
  network       = google_compute_network.vpc.id
  region        = var.config.project.region

  private_ip_google_access = true
}

resource "google_compute_router" "router" {
  name    = var.config.network.nat_router
  network = google_compute_network.vpc.id
  region  = var.config.project.region
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.config.network.nat_router}-nat"
  router                             = google_compute_router.router.name
  region                             = google_compute_router.router.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.private.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "TRANSLATIONS_ONLY"
  }
}
