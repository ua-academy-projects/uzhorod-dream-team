resource "google_secret_manager_secret_iam_member" "secret_members" {
  for_each = {
    for member in local.secret_members : member.key => member
  }

  project   = var.project_id
  secret_id = google_secret_manager_secret.secret[each.value.secret_name].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${each.value.email}"
}
