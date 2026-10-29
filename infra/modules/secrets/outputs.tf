output "ids" {
  value = sort(keys(google_secret_manager_secret.secret))
}
