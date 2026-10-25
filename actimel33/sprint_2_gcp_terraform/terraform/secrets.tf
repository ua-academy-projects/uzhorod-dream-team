locals {
  password_lengths = {
    postgres-password     = 32
    queue-worker-password = 32
    redis-password        = 32
    session-secret        = 64
  }

  secret_names = toset(concat(
    keys(local.password_lengths),
    [for name in local.services : "logship-key-${name}"],
  ))

  # Which role may read which secret; nothing else is granted.
  secret_readers = {
    db      = ["postgres-password", "queue-worker-password", "redis-password", "logship-key-db"]
    history = ["postgres-password", "session-secret", "redis-password", "logship-key-history"]
    fetcher = ["queue-worker-password", "redis-password", "logship-key-fetcher"]
    ui      = ["logship-key-ui"]
  }

  secret_grants = merge([
    for role, secrets in local.secret_readers : {
      for secret in secrets : "${role}/${secret}" => { role = role, secret = secret }
    }
  ]...)
}

ephemeral "random_password" "app" {
  for_each = local.password_lengths

  length  = each.value
  special = false # they end up inside postgres:// URLs
}

# The collector on db needs the public halves, so these keys live in the state.
resource "tls_private_key" "logship" {
  for_each = local.services

  algorithm = "ED25519"
}

resource "google_secret_manager_secret" "app" {
  for_each = local.secret_names

  secret_id = "crypto-${each.key}"

  replication {
    auto {}
  }

  depends_on = [google_project_service.this]
}

resource "google_secret_manager_secret_version" "password" {
  for_each = local.password_lengths

  secret                 = google_secret_manager_secret.app[each.key].id
  secret_data_wo         = ephemeral.random_password.app[each.key].result
  secret_data_wo_version = 1 # bump to rotate
}

resource "google_secret_manager_secret_version" "logship_key" {
  for_each = local.services

  secret                 = google_secret_manager_secret.app["logship-key-${each.key}"].id
  secret_data_wo         = tls_private_key.logship[each.key].private_key_openssh
  secret_data_wo_version = 1
}

resource "google_secret_manager_secret_iam_member" "reader" {
  for_each = local.secret_grants

  secret_id = google_secret_manager_secret.app[each.value.secret].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm[each.value.role].email}"
}
