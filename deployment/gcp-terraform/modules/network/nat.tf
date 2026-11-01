resource "google_compute_router" "main" {
  count = var.cfg.network.enable_nat ? 1 : 0

  project = var.cfg.google.project_id
  name    = "${var.cfg.network.name}-router"
  region  = var.cfg.google.region
  network = google_compute_network.main.id
}

resource "google_compute_router_nat" "main" {
  count = var.cfg.network.enable_nat ? 1 : 0

  project                            = var.cfg.google.project_id
  name                               = "${var.cfg.network.name}-nat"
  region                             = var.cfg.google.region
  router                             = google_compute_router.main[0].name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.private.id
    source_ip_ranges_to_nat = ["PRIMARY_IP_RANGE"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
