locals {
  enabled         = try(var.config.cloud_sql.managed, false)
  client_services = local.enabled && var.config.database.provider == "cloud_sql" ? toset(["fetcher", "history"]) : toset([])
  config          = var.config.cloud_sql
}

resource "google_project_service" "sqladmin" {
  count              = local.enabled ? 1 : 0
  project            = var.config.project_id
  service            = "sqladmin.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "service_networking" {
  count              = local.enabled ? 1 : 0
  project            = var.config.project_id
  service            = "servicenetworking.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_global_address" "private_services" {
  for_each      = local.enabled ? local.config.private_service_access.ranges : {}
  project       = var.config.project_id
  name          = each.key
  address       = each.value.address
  prefix_length = each.value.prefix_length
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  network       = var.network_id
  lifecycle { prevent_destroy = true }
}

resource "google_service_networking_connection" "private_services" {
  count                   = local.enabled ? 1 : 0
  network                 = var.network_id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = local.config.private_service_access.peering_ranges
  depends_on              = [google_compute_global_address.private_services, google_project_service.service_networking]
  lifecycle { prevent_destroy = true }
}

resource "google_sql_database_instance" "main" {
  count               = local.enabled ? 1 : 0
  project             = var.config.project_id
  name                = local.config.instance_name
  region              = local.config.region
  database_version    = local.config.database_version
  deletion_protection = true
  settings {
    tier                        = local.config.tier
    edition                     = local.config.edition
    availability_type           = local.config.availability_type
    activation_policy           = "ALWAYS"
    disk_size                   = local.config.disk_size_gb
    disk_type                   = local.config.disk_type
    disk_autoresize             = local.config.disk_autoresize
    deletion_protection_enabled = local.config.deletion_protection
    enable_dataplex_integration = local.config.enable_dataplex_integration
    data_cache_config { data_cache_enabled = local.config.data_cache_enabled }
    location_preference { zone = local.config.zone }
    ip_configuration {
      ipv4_enabled    = local.config.public_ip
      private_network = var.network_id
      ssl_mode        = "ALLOW_UNENCRYPTED_AND_ENCRYPTED"
    }
    dynamic "database_flags" {
      for_each = local.config.database_flags
      content {
        name  = database_flags.key
        value = database_flags.value
      }
    }
    backup_configuration {
      enabled                        = local.config.backup.enabled
      point_in_time_recovery_enabled = local.config.backup.point_in_time_recovery_enabled
      start_time                     = local.config.backup.start_time
      transaction_log_retention_days = local.config.backup.transaction_log_retention_days
      backup_retention_settings {
        retained_backups = local.config.backup.retained_backups
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
  count           = local.enabled ? 1 : 0
  project         = var.config.project_id
  instance        = google_sql_database_instance.main[0].name
  name            = var.config.database.name
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
  for_each = local.client_services
  project  = var.config.project_id
  role     = "roles/cloudsql.client"
  member   = "serviceAccount:${var.service_account_emails[each.key]}"
}
