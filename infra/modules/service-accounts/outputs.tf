output "emails" {
  description = "name => service account e-mail"
  value       = { for name, sa in google_service_account.sa : name => sa.email }
}

output "members" {
  description = "name => IAM member (serviceAccount:...)"
  value       = { for name, sa in google_service_account.sa : name => "serviceAccount:${sa.email}" }
}
