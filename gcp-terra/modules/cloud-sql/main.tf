resource "google_project_service" "sqladmin" {
  project            = var.project_id
  service            = "sqladmin.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "service_networking" {
  project            = var.project_id
  service            = "servicenetworking.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_global_address" "private_services" {
  for_each      = var.config.private_service_access.ranges
  project       = var.project_id
  name          = each.key
  address       = each.value.address
  prefix_length = each.value.prefix_length
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  network       = var.network_id
  lifecycle { prevent_destroy = true }
}

resource "google_service_networking_connection" "private_services" {
  network                 = var.network_id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = var.config.private_service_access.peering_ranges
  depends_on              = [google_compute_global_address.private_services, google_project_service.service_networking]
  lifecycle { prevent_destroy = true }
}

resource "google_sql_database_instance" "main" {
  project             = var.project_id
  name                = var.config.instance_name
  region              = var.config.region
  database_version    = var.config.database_version
  deletion_protection = true
  settings {
    tier                        = var.config.tier
    edition                     = var.config.edition
    availability_type           = var.config.availability_type
    activation_policy           = "ALWAYS"
    disk_size                   = var.config.disk_size_gb
    disk_type                   = var.config.disk_type
    disk_autoresize             = var.config.disk_autoresize
    deletion_protection_enabled = var.config.deletion_protection
    enable_dataplex_integration = var.config.enable_dataplex_integration
    data_cache_config { data_cache_enabled = var.config.data_cache_enabled }
    location_preference { zone = var.config.zone }
    ip_configuration {
      ipv4_enabled    = var.config.public_ip
      private_network = var.network_id
      ssl_mode        = "ALLOW_UNENCRYPTED_AND_ENCRYPTED"
    }
    dynamic "database_flags" {
      for_each = var.config.database_flags
      content {
        name  = database_flags.key
        value = database_flags.value
      }
    }
    backup_configuration {
      enabled                        = var.config.backup.enabled
      point_in_time_recovery_enabled = var.config.backup.point_in_time_recovery_enabled
      start_time                     = var.config.backup.start_time
      transaction_log_retention_days = var.config.backup.transaction_log_retention_days
      backup_retention_settings {
        retained_backups = var.config.backup.retained_backups
        retention_unit   = "COUNT"
      }
    }
  }
  depends_on = [google_project_service.sqladmin, google_service_networking_connection.private_services]
  lifecycle {
    prevent_destroy = true
    # GCP reports a zero maintenance window for this existing instance.
    ignore_changes = [settings[0].maintenance_window]
  }
}

resource "google_sql_database" "application" {
  project         = var.project_id
  instance        = google_sql_database_instance.main.name
  name            = var.database_name
  charset         = "UTF8"
  collation       = "en_US.UTF8"
  deletion_policy = "ABANDON"
  lifecycle {
    prevent_destroy = true
    # Provider 6.8 sends unsupported PostgreSQL PATCH requests for this state-only field.
    # Set it on creation; preserve the adopted value without an API update.
    ignore_changes = [deletion_policy]
  }
}

resource "google_project_iam_member" "client" {
  for_each = var.client_services
  project  = var.project_id
  role     = "roles/cloudsql.client"
  member   = "serviceAccount:${var.service_account_emails[each.key]}"
}
