# A deleted instance name stays taken for about a week.
resource "random_id" "suffix" {
  byte_length = 2
  keepers = {
    region = var.project.region
  }
}

#trivy:ignore:GCP-0024
resource "google_sql_database_instance" "this" {
  name                = "${var.config.name}-${random_id.suffix.hex}"
  region              = var.project.region
  database_version    = var.config.database_version
  deletion_protection = var.config.deletion_protection

  settings {
    edition                     = var.config.edition
    tier                        = var.config.tier
    availability_type           = var.config.availability_type
    disk_size                   = var.config.disk_size
    disk_type                   = var.config.disk_type
    deletion_protection_enabled = var.config.deletion_protection
    user_labels                 = var.project.labels
    # No SQL through the Cloud SQL Data API either: only connections through the endpoint.
    data_api_access = "DISALLOW_DATA_API"

    # No public IP: the only way in is the Private Service Connect endpoint below.
    ip_configuration {
      ipv4_enabled = false
      ssl_mode     = "ENCRYPTED_ONLY"
      # The instance has its own CA.
      server_ca_mode = "GOOGLE_MANAGED_INTERNAL_CA"

      psc_config {
        psc_enabled               = true
        allowed_consumer_projects = [var.project.id]
      }
    }

    # ALTER ROLE ... PASSWORD must not reach the logs: neither as a failed statement nor as a logged one.
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

# ABANDON: destroy deletes the instance with everything in it.
resource "google_sql_database" "this" {
  name            = var.config.database
  instance        = google_sql_database_instance.this.name
  deletion_policy = "ABANDON"
}

# The password comes from the secret the VMs read.
ephemeral "google_secret_manager_secret_version" "password" {
  secret  = var.config.password_secret
  version = var.secret_versions[var.config.password_secret]
}

resource "google_sql_user" "app" {
  name                = var.config.user
  instance            = google_sql_database_instance.this.name
  password_wo         = ephemeral.google_secret_manager_secret_version.password.secret_data
  password_wo_version = tonumber(var.secret_versions[var.config.password_secret])
  deletion_policy     = "ABANDON"
}

# The endpoint: an internal IP in the private subnet that leads to the instance.
resource "google_compute_address" "endpoint" {
  name         = var.config.endpoint
  region       = var.project.region
  subnetwork   = var.subnets.private
  address_type = "INTERNAL"
  labels       = var.project.labels
}

resource "google_compute_forwarding_rule" "endpoint" {
  name                  = var.config.endpoint
  region                = var.project.region
  network               = var.network
  ip_address            = google_compute_address.endpoint.id
  target                = google_sql_database_instance.this.psc_service_attachment_link
  load_balancing_scheme = ""
}
