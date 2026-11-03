output "names" {
  value = { for key, secret in google_secret_manager_secret.secret : key => secret.secret_id }
}
