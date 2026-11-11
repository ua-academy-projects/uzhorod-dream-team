output "vms" {
  description = "The VMs that exist: name => bastion, the services that run on it, the secrets it reads (the switches applied)"
  value       = local.vms
}

output "emails" {
  description = "name => service account e-mail"
  value       = { for name, sa in google_service_account.sa : name => sa.email }
}

output "members" {
  description = "name => IAM member (serviceAccount:...)"
  value       = { for name, sa in google_service_account.sa : name => "serviceAccount:${sa.email}" }
}
