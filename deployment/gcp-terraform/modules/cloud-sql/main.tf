resource "google_sql_database_instance" "main" {
  project             = var.cfg.google.project_id
  name                = var.cfg.cloud_sql.name
  region              = var.cfg.google.region
  database_version    = "POSTGRES_16"
  deletion_protection = true
  settings {
    edition                     = "ENTERPRISE"
    tier                        = var.cfg.cloud_sql.tier
    availability_type           = "ZONAL"
    disk_type                   = "PD_SSD"
    disk_size                   = var.cfg.cloud_sql.disk_size_gb
    disk_autoresize             = true
    deletion_protection_enabled = true
    location_preference { zone = var.cfg.google.zone }
    backup_configuration {
      enabled                        = true
      start_time                     = "03:00"
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 7
        retention_unit   = "COUNT"
      }
    }
    ip_configuration {
      ipv4_enabled = false
      ssl_mode     = "ENCRYPTED_ONLY"
      psc_config {
        psc_enabled               = true
        allowed_consumer_projects = [var.cfg.google.project_id]
      }
    }
  }
}

resource "google_sql_database" "application" {
  project  = var.cfg.google.project_id
  instance = google_sql_database_instance.main.name
  name     = var.cfg.application.database_name
}

