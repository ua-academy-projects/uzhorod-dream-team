locals {
  labels = { app = var.config.prefix, managed-by = "terraform" }
}

resource "google_secret_manager_secret" "secret" {
  for_each  = toset(var.secrets)
  secret_id = "${var.config.prefix}-${each.key}"
  labels    = local.labels

  replication {
    auto {}
  }
}