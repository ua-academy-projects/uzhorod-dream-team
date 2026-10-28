resource "google_secret_manager_secret_version" "secret" {
  for_each = var.secrets_to_set

  secret = google_secret_manager_secret.secret[each.value].id
  secret_data_wo = var.payloads[each.value]
  secret_data_wo_version = lookup(var.revisions, each.value, 1)

  lifecycle {
    create_before_destroy = true
  }
}
