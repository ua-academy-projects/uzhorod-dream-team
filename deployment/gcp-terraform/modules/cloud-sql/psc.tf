resource "google_compute_address" "endpoint" {
  project      = var.cfg.google.project_id
  name         = "${var.cfg.cloud_sql.name}-psc"
  region       = var.cfg.google.region
  address_type = "INTERNAL"
  subnetwork   = var.network.subnetwork_id
}

resource "google_compute_forwarding_rule" "endpoint" {
  project               = var.cfg.google.project_id
  name                  = "${var.cfg.cloud_sql.name}-psc"
  region                = var.cfg.google.region
  network               = var.network.network_id
  ip_address            = google_compute_address.endpoint.self_link
  target                = google_sql_database_instance.main.psc_service_attachment_link
  load_balancing_scheme = ""
}

