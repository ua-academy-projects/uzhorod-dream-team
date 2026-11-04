locals {
  cfg = var.config
}

resource "google_compute_global_address" "private_range" {
  name          = "${local.cfg.name}-private-range"
  network       = local.cfg.network_id
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  address       = split("/", local.cfg.private_range)[0]
  prefix_length = tonumber(split("/", local.cfg.private_range)[1])
}

resource "google_service_networking_connection" "private" {
  network                 = local.cfg.network_id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_range.name]
}

resource "google_sql_database_instance" "pg" {
  name                = local.cfg.name
  region              = local.cfg.region
  database_version    = local.cfg.version
  deletion_protection = true

  settings {
    edition           = "ENTERPRISE"
    tier              = local.cfg.tier
    availability_type = "ZONAL"
    disk_size         = local.cfg.disk_size_gb
    disk_autoresize   = true
    user_labels       = local.cfg.labels

    location_preference {
      zone = local.cfg.zone
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = local.cfg.network_id
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
  name     = local.cfg.database
  instance = google_sql_database_instance.pg.name
}
