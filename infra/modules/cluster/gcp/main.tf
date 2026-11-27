locals {
  name = "${var.config.prefix}-k3s"
  tag  = "k3s"
}

resource "google_compute_address" "api" {
  name         = "${local.name}-api"
  region       = var.region
  subnetwork   = var.subnet_id
  address_type = "INTERNAL"
  address      = cidrhost(var.subnet_cidr, var.api_nlb_ip_index)
}

resource "google_compute_instance_group" "servers" {
  name      = "${local.name}-servers"
  zone      = var.zone
  network   = var.network_id
  instances = values(var.servers)
}

resource "google_compute_region_health_check" "api" {
  name   = "${local.name}-api"
  region = var.region

  tcp_health_check {
    port = 6443
  }
}

resource "google_compute_region_backend_service" "api" {
  name                  = "${local.name}-api"
  region                = var.region
  protocol              = "TCP"
  load_balancing_scheme = "INTERNAL"
  health_checks         = [google_compute_region_health_check.api.id]

  backend {
    group          = google_compute_instance_group.servers.id
    balancing_mode = "CONNECTION"
  }
}

resource "google_compute_forwarding_rule" "api" {
  name                  = "${local.name}-api"
  region                = var.region
  load_balancing_scheme = "INTERNAL"
  backend_service       = google_compute_region_backend_service.api.id
  ip_protocol           = "TCP"
  ports                 = ["6443"]
  ip_address            = google_compute_address.api.address
  network               = var.network_id
  subnetwork            = var.subnet_id
}

resource "google_compute_firewall" "nodes" {
  name          = "${local.name}-nodes"
  network       = var.network_id
  source_ranges = [var.subnet_cidr]
  target_tags   = [local.tag]

  allow {
    protocol = "tcp"
    ports    = ["6443", "2379-2380", "10250"]
  }
  allow {
    protocol = "udp"
    ports    = ["8472"]
  }
}

resource "google_compute_firewall" "health_checks" {
  name          = "${local.name}-health-checks"
  network       = var.network_id
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = [local.tag]

  allow {
    protocol = "tcp"
    ports    = ["6443"]
  }
}