locals {
  grants = merge([
    for secret_id, secret in var.config.secrets : {
      for reader in secret.readers : "${secret_id}/${reader}" => { secret_id = secret_id, reader = reader }
      if contains(keys(var.readers), reader)
    }
  ]...)
}

ephemeral "random_password" "password" {
  for_each = var.config.secrets

  length  = each.value.length
  special = false
}

resource "google_secret_manager_secret" "password" {
  for_each = var.config.secrets

  secret_id = each.key

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "password" {
  for_each = var.config.secrets

  secret                 = google_secret_manager_secret.password[each.key].id
  secret_data_wo         = ephemeral.random_password.password[each.key].result
  secret_data_wo_version = each.value.version
}

resource "google_secret_manager_secret_iam_member" "reader" {
  for_each = local.grants

  secret_id = google_secret_manager_secret.password[each.value.secret_id].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.readers[each.value.reader]}"
}
