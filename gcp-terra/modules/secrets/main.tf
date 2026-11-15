locals {
  config = var.config.secret_manager
}

resource "google_secret_manager_secret" "datamonitor_env" {
  secret_id = local.config.secret_id

  replication {
    auto {}
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_service_account" "datamonitor" {
  account_id   = local.config.account_id
  display_name = local.config.display_name
}

resource "google_secret_manager_secret_iam_member" "datamonitor_access" {
  for_each = local.config.roles

  secret_id = google_secret_manager_secret.datamonitor_env.id
  role      = each.value
  member    = "serviceAccount:${google_service_account.datamonitor.email}"
}

# The legacy secret/account remain for migration; new VM accounts cannot read it.
resource "google_secret_manager_secret" "service_env" {
  for_each  = local.config.services
  secret_id = each.value.secret_id
  replication {
    auto {}
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_service_account" "service" {
  for_each     = local.config.services
  account_id   = each.value.account_id
  display_name = each.value.display_name
}

resource "google_secret_manager_secret_iam_member" "service_access" {
  for_each  = local.config.services
  secret_id = google_secret_manager_secret.service_env[each.key].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.service[each.key].email}"
}
