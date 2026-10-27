output "service_account_emails" {
  description = "Map look like vm_name => email_service_account"
  value       = { for k, v in google_service_account.vm_sa : k => v.email }
}
