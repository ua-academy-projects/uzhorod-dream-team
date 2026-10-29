resource "google_secret_manager_secret" "datamonitor_env" {
  secret_id = "datamonitor-env"

  replication {
    auto {}
  }
}

resource "google_service_account" "datamonitor" {
  account_id   = "datamonitor-vm"
  display_name = "Data Monitor VM Service Account"
}

resource "google_secret_manager_secret_iam_member" "datamonitor_access" {
  secret_id = google_secret_manager_secret.datamonitor_env.id

  role = "roles/secretmanager.secretAccessor"

  member = "serviceAccount:${google_service_account.datamonitor.email}"
}
