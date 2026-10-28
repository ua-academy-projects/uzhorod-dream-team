resource "google_compute_network" "vpc" {
  name                    = var.secure_vpc
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "management" {
  name          = var.management_subnet
  ip_cidr_range = var.management_cidr
  network       = google_compute_network.vpc.id
  region        = var.management_subnet_region

}

resource "google_compute_subnetwork" "private" {
  name          = var.private_network
  ip_cidr_range = var.private_cidr
  network       = google_compute_network.vpc.id
  region        = var.private_subnet_region

  # Enables access to google services without publick IP
  private_ip_google_access = true
}

resource "google_compute_router" "router" {
  name    = var.nat_router_name
  network = google_compute_network.vpc.id
  region  = var.nat_router_region
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.nat_router_name}-nat"
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
