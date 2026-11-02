# A deleted instance name stays taken for about a week.
resource "random_id" "suffix" {
  byte_length = 2
  keepers = {
    region = var.config.project.region
  }
}

#trivy:ignore:GCP-0024
resource "google_sql_database_instance" "postgres" {
  name                = "${var.config.cloud_sql.name}-${random_id.suffix.hex}"
  region              = var.config.project.region
  database_version    = var.config.cloud_sql.database_version
  deletion_protection = var.config.cloud_sql.deletion_protection

  settings {
    edition                     = var.config.cloud_sql.edition
    tier                        = var.config.cloud_sql.tier
    availability_type           = var.config.cloud_sql.availability_type
    disk_size                   = var.config.cloud_sql.disk_size
    disk_type                   = var.config.cloud_sql.disk_type
    deletion_protection_enabled = var.config.cloud_sql.deletion_protection
    user_labels                 = var.config.project.labels
    data_api_access             = "DISALLOW_DATA_API"

    ip_configuration {
      ipv4_enabled   = false
      ssl_mode       = "ENCRYPTED_ONLY"
      server_ca_mode = "GOOGLE_MANAGED_INTERNAL_CA"

      psc_config {
        psc_enabled               = true
        allowed_consumer_projects = [var.config.project.id]
      }
    }

    database_flags {
      name  = "log_min_error_statement"
      value = "panic"
    }
    database_flags {
      name  = "log_statement"
      value = "none"
    }

    # Who connected and when.
    database_flags {
      name  = "log_connections"
      value = "on"
    }
    database_flags {
      name  = "log_disconnections"
      value = "on"
    }
  }
}

resource "google_sql_database" "app" {
  name            = var.config.cloud_sql.database
  instance        = google_sql_database_instance.postgres.name
  deletion_policy = "ABANDON"
}

ephemeral "google_secret_manager_secret_version" "password" {
  secret  = var.config.cloud_sql.password_secret
  version = var.secret_versions[var.config.cloud_sql.password_secret]
}

resource "google_sql_user" "app" {
  name                = var.config.cloud_sql.user
  instance            = google_sql_database_instance.postgres.name
  password_wo         = ephemeral.google_secret_manager_secret_version.password.secret_data
  password_wo_version = tonumber(var.secret_versions[var.config.cloud_sql.password_secret])
  deletion_policy     = "ABANDON"
}

# The endpoint: an internal IP in the private subnet that leads to the instance.
resource "google_compute_address" "endpoint" {
  name         = var.config.cloud_sql.endpoint
  region       = var.config.project.region
  subnetwork   = var.subnets.private
  address_type = "INTERNAL"
  labels       = var.config.project.labels
}

resource "google_compute_forwarding_rule" "endpoint" {
  name                  = var.config.cloud_sql.endpoint
  region                = var.config.project.region
  network               = var.network
  ip_address            = google_compute_address.endpoint.id
  target                = google_sql_database_instance.postgres.psc_service_attachment_link
  load_balancing_scheme = ""
}
