# The private network: one VPC with one subnet, internet OUT through Cloud NAT

locals {
  cfg = var.config
}

resource "google_compute_network" "vpc" {
  name                    = local.cfg.name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "private" {
  name                     = "${local.cfg.name}-private"
  region                   = local.cfg.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = local.cfg.subnet_cidr
  private_ip_google_access = true
}

# internet OUT (Docker Hub, CityBikes API, Cloudflare)
resource "google_compute_router" "router" {
  name    = "${local.cfg.name}-router"
  region  = local.cfg.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${local.cfg.name}-nat"
  router                             = google_compute_router.router.name
  region                             = local.cfg.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# firewall
resource "google_compute_firewall" "ssh_to_bastion" {
  name          = "${local.cfg.name}-ssh-to-bastion"
  network       = google_compute_network.vpc.id
  source_ranges = local.cfg.ssh_allowed_cidrs
  target_tags   = [local.cfg.bastion_tag]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "ssh_from_bastion" {
  name        = "${local.cfg.name}-ssh-from-bastion"
  network     = google_compute_network.vpc.id
  source_tags = [local.cfg.bastion_tag]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# VM <-> VM: only the services' ports
resource "google_compute_firewall" "internal" {
  name          = "${local.cfg.name}-internal"
  network       = google_compute_network.vpc.id
  source_ranges = [local.cfg.subnet_cidr]

  allow {
    protocol = "tcp"
    ports    = local.cfg.internal_ports
  }
  allow {
    protocol = "icmp"
  }
}
