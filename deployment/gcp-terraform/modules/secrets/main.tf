resource "google_secret_manager_secret" "secret" {
  for_each = local.names

  project   = local.project_id
  secret_id = each.value
  replication {
    auto {}
  }
}
