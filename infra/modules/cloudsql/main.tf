locals {
  name     = "${var.config.prefix}-pg"
  database = var.config.database.cloudsql
  labels   = { app = var.config.prefix, managed-by = "terraform" }
}

resource "google_compute_global_address" "private_range" {
  name          = "${local.name}-private-range"
  network       = var.network_id
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  address       = split("/", local.database.private_range)[0]
  prefix_length = tonumber(split("/", local.database.private_range)[1])
}

resource "google_service_networking_connection" "private" {
  network                 = var.network_id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_range.name]
}

resource "google_sql_database_instance" "pg" {
  name                = local.name
  region              = var.config.location.region
  database_version    = local.database.version
  deletion_protection = local.database.deletion_protection

  settings {
    edition           = "ENTERPRISE"
    tier              = local.database.tier
    availability_type = "ZONAL"
    disk_size         = local.database.disk_size_gb
    disk_autoresize   = true
    user_labels       = local.labels

    location_preference {
      zone = var.config.location.zone
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network_id
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled    = true
      start_time = "03:00"
    }
  }

  depends_on = [google_service_networking_connection.private]
}

resource "google_sql_database" "app" {
  name                = var.config.app.db_name
  instance            = google_sql_database_instance.pg.name
}
