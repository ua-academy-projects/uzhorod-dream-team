output "vm_emails" {
  description = "VM name => email of its service account"
  value       = { for name, account in google_service_account.vm : name => account.email }
}

output "emails" {
  description = "Name in service_accounts of config.json => email of the account"
  value       = { for name, account in google_service_account.account : name => account.email }
}
