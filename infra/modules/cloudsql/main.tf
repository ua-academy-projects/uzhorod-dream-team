resource "random_id" "suffix" {
  byte_length = 2
}

resource "google_sql_database_instance" "this" {
  name                = "${var.config.project.name_prefix}-pg-${random_id.suffix.hex}"
  region              = var.config.project.region
  database_version    = var.config.cloudsql.version
  deletion_protection = var.config.cloudsql.deletion_protection

  settings {
    tier                  = var.config.cloudsql.tier
    edition               = var.config.cloudsql.edition
    availability_type     = "ZONAL"
    disk_type             = "PD_SSD"
    disk_size             = var.config.cloudsql.disk_gb
    disk_autoresize       = false
    connector_enforcement = "REQUIRED"

    user_labels = {
      iss-prefix = var.config.project.name_prefix
    }

    location_preference {
      zone = var.config.project.zone
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network_id
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = false
    }

    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }

    database_flags {
      name  = "cloudsql.enable_pg_cron"
      value = "on"
    }
  }
}

resource "google_sql_database" "this" {
  name            = var.config.postgres.database_name
  instance        = google_sql_database_instance.this.name
  deletion_policy = "ABANDON"
}

resource "google_sql_user" "iam" {
  for_each = var.iam_users

  name            = each.value
  instance        = google_sql_database_instance.this.name
  type            = "CLOUD_IAM_SERVICE_ACCOUNT"
  deletion_policy = "ABANDON"
}
