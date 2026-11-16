locals {
  name     = "${var.config.prefix}-pg"
  gcp      = var.config.clouds.gcp
  database = var.config.database.managed
  labels   = { app = var.config.prefix, managed-by = "terraform" }
}

resource "google_compute_global_address" "private_range" {
  name          = "${local.name}-private-range"
  network       = var.network_id
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  address       = split("/", local.gcp.database_private_range)[0]
  prefix_length = tonumber(split("/", local.gcp.database_private_range)[1])
}

resource "google_service_networking_connection" "private" {
  network                 = var.network_id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_range.name]
  deletion_policy         = "ABANDON"
}

resource "google_sql_database_instance" "pg" {
  name                = local.name
  region              = local.gcp.region
  database_version    = "POSTGRES_${local.database.version}"
  deletion_protection = local.database.deletion_protection

  settings {
    edition           = "ENTERPRISE"
    tier              = local.gcp.database_sizes[local.database.size]
    availability_type = "ZONAL"
    disk_size         = local.database.disk_gb
    disk_autoresize   = true
    user_labels       = local.labels

    location_preference {
      zone = local.gcp.zones[0]
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
  name            = var.config.app.db_name
  instance        = google_sql_database_instance.pg.name
  deletion_policy = "ABANDON"
}
