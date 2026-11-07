locals {
  name        = "${var.config.prefix}-vpc"
  region      = var.config.location.region
  network     = var.config.network
  bastion_tag = "bastion"
}

resource "google_compute_network" "vpc" {
  name                    = local.name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "private" {
  name                     = "${local.name}-private"
  region                   = local.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = local.network.subnet_cidr
  private_ip_google_access = true
}

resource "google_compute_router" "router" {
  name    = "${local.name}-router"
  region  = local.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${local.name}-nat"
  router                             = google_compute_router.router.name
  region                             = local.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# firewall
resource "google_compute_firewall" "ssh_to_bastion" {
  name          = "${local.name}-ssh-to-bastion"
  network       = google_compute_network.vpc.id
  source_ranges = var.ssh_allowed_cidrs
  target_tags   = [local.bastion_tag]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "ssh_from_bastion" {
  name        = "${local.name}-ssh-from-bastion"
  network     = google_compute_network.vpc.id
  source_tags = [local.bastion_tag]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# VM <-> VM: only the services' ports
resource "google_compute_firewall" "internal" {
  name          = "${local.name}-internal"
  network       = google_compute_network.vpc.id
  source_ranges = [local.network.subnet_cidr]

  allow {
    protocol = "tcp"
    ports    = local.network.internal_ports
  }
  allow {
    protocol = "icmp"
  }
}
