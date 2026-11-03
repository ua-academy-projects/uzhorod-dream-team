resource "google_secret_manager_secret" "secret" {
  for_each = var.config.secrets

  secret_id = "${var.config.project.prefix}-${each.key}"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "accessor" {
  for_each = merge([
    for secret, settings in var.config.secrets : {
      for account in settings.accessors : "${secret}/${account}" => { secret = secret, account = account }
    }
  ]...)

  secret_id = google_secret_manager_secret.secret[each.value.secret].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.service_accounts[each.value.account]}"
}
