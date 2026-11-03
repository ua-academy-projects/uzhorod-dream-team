resource "google_compute_global_address" "peering" {
  name          = "${var.config.project.prefix}-cloudsql-peering"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = var.config.cloudsql.peering_prefix_length
  network       = var.networks[var.config.cloudsql.network]
}

resource "google_service_networking_connection" "peering" {
  network                 = var.networks[var.config.cloudsql.network]
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.peering.name]
  deletion_policy         = "ABANDON"
}

resource "google_sql_database_instance" "db" {
  name                = "${var.config.project.prefix}-db"
  database_version    = var.config.cloudsql.version
  deletion_protection = var.config.cloudsql.deletion_protection

  settings {
    tier              = var.config.cloudsql.tier
    edition           = var.config.cloudsql.edition
    availability_type = "ZONAL"
    disk_size         = var.config.cloudsql.disk_gb

    location_preference {
      zone = var.config.project.zone
    }

    backup_configuration {
      enabled = true
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.networks[var.config.cloudsql.network]
      ssl_mode        = "ENCRYPTED_ONLY"
    }
  }

  depends_on = [google_service_networking_connection.peering]
}

resource "google_sql_database" "app" {
  name     = var.config.cloudsql.database
  instance = google_sql_database_instance.db.name
}
