ephemeral "google_secret_manager_secret_version" "migration" {
  project = var.cfg.google.project_id
  secret  = var.secrets.secrets["postgres-migration-password"].secret_id
  version = var.secrets.secrets["postgres-migration-password"].version
}

resource "google_sql_user" "migration" {
  project             = var.cfg.google.project_id
  instance            = google_sql_database_instance.main.name
  name                = "kyiv_air_migrate"
  password_wo         = ephemeral.google_secret_manager_secret_version.migration.secret_data
  password_wo_version = lookup(var.revisions, "postgres-migration-password", 1)
}
