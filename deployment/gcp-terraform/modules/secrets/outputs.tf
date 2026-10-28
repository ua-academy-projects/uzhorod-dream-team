output "secrets" {
  value = {
    for name, secret in google_secret_manager_secret.secret :
    name => {
      id        = secret.id
      secret_id = secret.secret_id
      version   = try(google_secret_manager_secret_version.secret[name].version, null)
    }
  }
}
