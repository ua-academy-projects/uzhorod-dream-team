# Private Service Access: Cloud SQL lives in a Google-owned project and is peered into our VPC
resource "google_compute_global_address" "range" {
  name          = var.private_range.name
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  address       = cidrhost(var.private_range.cidr, 0)
  prefix_length = tonumber(split("/", var.private_range.cidr)[1])
  network       = var.network_id
}

resource "google_service_networking_connection" "psa" {
  network                 = var.network_id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.range.name]
  deletion_policy         = "ABANDON"
}

resource "google_sql_database_instance" "pg" {
  name                = var.name
  region              = var.region
  database_version    = var.database_version
  deletion_protection = var.deletion_protection

  settings {
    tier              = var.tier
    edition           = var.edition
    availability_type = var.availability_type
    disk_size         = var.disk_size_gb
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network_id
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled                        = var.backup.enabled
      point_in_time_recovery_enabled = var.backup.point_in_time_recovery
      start_time                     = var.backup.start_time
    }

    dynamic "location_preference" {
      for_each = var.zone == null ? [] : [var.zone]
      content {
        zone = location_preference.value
      }
    }
  }

  depends_on = [google_service_networking_connection.psa]
}

resource "google_sql_database" "db" {
  for_each = var.databases
  name     = each.value.name
  instance = google_sql_database_instance.pg.name
}

resource "google_sql_user" "user" {
  for_each = var.databases
  name     = each.value.user
  instance = google_sql_database_instance.pg.name
  password = var.passwords[each.key]
}
