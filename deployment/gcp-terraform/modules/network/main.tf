resource "google_compute_network" "main" {
  project                 = var.cfg.google.project_id
  name                    = var.cfg.network.name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "private" {
  project                  = var.cfg.google.project_id
  name                     = "${var.cfg.network.name}-private"
  region                   = var.cfg.google.region
  network                  = google_compute_network.main.id
  ip_cidr_range            = var.cfg.network.subnet_cidr
  private_ip_google_access = true
}
