resource "google_compute_network" "main" {
  project                 = var.project_id
  name                    = var.config.name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "private" {
  project                  = var.project_id
  name                     = "${var.config.name}-private"
  region                   = var.region
  network                  = google_compute_network.main.id
  ip_cidr_range            = var.config.subnet_cidr
  private_ip_google_access = true
}
