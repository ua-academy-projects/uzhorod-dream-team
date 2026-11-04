output "secret_ids" {
  description = "Secret IDs, for gcloud secrets versions access in the start scripts on the VMs"
  value       = [for secret in google_secret_manager_secret.password : secret.secret_id]
}

output "versions" {
  description = "Secret ID => its current version, for reading a secret in Terraform"
  value       = { for secret_id, version in google_secret_manager_secret_version.password : secret_id => version.version }
}
