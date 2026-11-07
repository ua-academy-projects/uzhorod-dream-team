output "service_account_emails" {
  value = { for key, account in google_service_account.service : key => account.email }
}

output "env_secret_ids" {
  value = { for key, secret in google_secret_manager_secret.service_env : key => secret.secret_id }
}
