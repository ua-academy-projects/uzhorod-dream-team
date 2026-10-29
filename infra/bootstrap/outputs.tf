output "state_bucket" {
  description = "Goes into bootstrap/backend.tf and envs/dev/backend.hcl"
  value       = google_storage_bucket.tfstate.name
}

output "terraform_service_account" {
  value = google_service_account.terraform.email
}

output "env_file" {
  description = "source this file before working with infra/envs/dev"
  value       = local_sensitive_file.env.filename
}
