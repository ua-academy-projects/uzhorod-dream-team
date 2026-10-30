locals {
  grants = merge([
    for secret_id, secret in var.config : {
      for reader in secret.readers : "${secret_id}/${reader}" => { secret_id = secret_id, reader = reader }
    }
  ]...)
}

# Ephemeral: the password is never written to the state, only to Secret Manager.
ephemeral "random_password" "this" {
  for_each = var.config

  length  = each.value.length
  special = false # passwords end up inside postgres:// URLs
}

resource "google_secret_manager_secret" "this" {
  for_each = var.config

  secret_id = each.key

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "this" {
  for_each = var.config

  secret                 = google_secret_manager_secret.this[each.key].id
  secret_data_wo         = ephemeral.random_password.this[each.key].result
  secret_data_wo_version = each.value.version
}

# Each VM reads only the secrets listed for it.
resource "google_secret_manager_secret_iam_member" "reader" {
  for_each = local.grants

  secret_id = google_secret_manager_secret.this[each.value.secret_id].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.readers[each.value.reader]}"
}
