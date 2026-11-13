resource "google_compute_network" "this" {
  name                    = "${var.config.project.name_prefix}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "this" {
  name                     = "${var.config.project.name_prefix}-subnet"
  network                  = google_compute_network.this.id
  region                   = var.config.project.region
  ip_cidr_range            = var.config.network.subnet_cidr
  private_ip_google_access = true
}

resource "google_compute_router" "this" {
  name    = "${var.config.project.name_prefix}-router"
  network = google_compute_network.this.id
  region  = var.config.project.region
}

resource "google_compute_router_nat" "this" {
  name                               = "${var.config.project.name_prefix}-nat"
  router                             = google_compute_router.this.name
  region                             = var.config.project.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.this.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

locals {
  psa = var.config.app.POSTGRES_BACKEND == "cloudsql" ? 1 : 0
}

resource "google_compute_global_address" "psa" {
  count = local.psa

  name          = "${var.config.project.name_prefix}-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  address       = split("/", var.config.network.psa_cidr)[0]
  prefix_length = tonumber(split("/", var.config.network.psa_cidr)[1])
  network       = google_compute_network.this.id
}

resource "google_service_networking_connection" "psa" {
  count = local.psa

  network                 = google_compute_network.this.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa[0].name]
  deletion_policy         = "ABANDON"
}

resource "google_compute_address" "internal" {
  for_each = { for k, v in var.config.vms : k => v.host }

  name         = "${var.config.project.name_prefix}-${each.key}-internal"
  region       = var.config.project.region
  subnetwork   = google_compute_subnetwork.this.id
  address_type = "INTERNAL"
  address      = cidrhost(var.config.network.subnet_cidr, each.value)
}
