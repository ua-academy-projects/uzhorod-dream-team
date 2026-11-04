resource "google_dns_managed_zone" "database" {
  project    = var.cfg.google.project_id
  name       = "${var.cfg.cloud_sql.name}-private"
  dns_name   = google_sql_database_instance.main.dns_name
  visibility = "private"
  private_visibility_config {
    networks { network_url = var.network.network_id }
  }
}

resource "google_dns_record_set" "database" {
  project      = var.cfg.google.project_id
  managed_zone = google_dns_managed_zone.database.name
  name         = google_sql_database_instance.main.dns_name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.endpoint.address]
}

