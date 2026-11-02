output "secret_ids" {
  description = "Secret IDs, for gcloud secrets versions access in startup scripts"
  value       = [for secret in google_secret_manager_secret.this : secret.secret_id]
}

output "versions" {
  description = "Secret ID => its current version, for reading a secret in Terraform"
  value       = { for secret_id, version in google_secret_manager_secret_version.this : secret_id => version.version }
}
