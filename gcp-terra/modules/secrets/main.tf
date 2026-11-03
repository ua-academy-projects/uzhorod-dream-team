resource "google_secret_manager_secret" "datamonitor_env" {
  secret_id = var.config.secret_id

  replication {
    auto {}
  }
}

resource "google_service_account" "datamonitor" {
  account_id   = var.config.account_id
  display_name = var.config.display_name
}

resource "google_secret_manager_secret_iam_member" "datamonitor_access" {
  for_each = var.config.roles

  secret_id = google_secret_manager_secret.datamonitor_env.id
  role      = each.value
  member    = "serviceAccount:${google_service_account.datamonitor.email}"
}
