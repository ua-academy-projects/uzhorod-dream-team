output "ids" {
  description = "secret (its config.json name) => its id in Secret Manager"
  value       = { for name, secret in google_secret_manager_secret.secret : name => secret.id }
}
