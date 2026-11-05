locals {
  client_vms = var.cfg.modes.postgres_only ? ["history", "fetcher"] : ["history"]
}

resource "google_project_iam_member" "client" {
  for_each = { for name in local.client_vms : name => var.service_accounts[name] }

  project = var.cfg.google.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${each.value.email}"
}
