output "service_account_email" {
  value = google_service_account.datamonitor.email
}

output "env_secret_id" {
  value = google_secret_manager_secret.datamonitor_env.secret_id
}
