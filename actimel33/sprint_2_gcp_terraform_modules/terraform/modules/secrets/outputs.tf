output "secret_ids" {
  description = "Secret IDs, for gcloud secrets versions access in startup scripts"
  value       = [for secret in google_secret_manager_secret.this : secret.secret_id]
}
