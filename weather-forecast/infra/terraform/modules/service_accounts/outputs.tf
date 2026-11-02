output "emails" {
  value = { for key, sa in google_service_account.vm : key => sa.email }
}
