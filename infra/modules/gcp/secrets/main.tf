# Secret Manager

locals {
  labels  = { app = var.config.prefix, managed-by = "terraform" }
  access  = { for vm, cfg in var.vms : vm => [for s in cfg.secrets : "${var.config.prefix}-${s}"] }
  secrets = toset(flatten(values(local.access)))

  grants = merge([
    for vm, secrets in local.access : {
      for secret in secrets : "${secret}/${vm}" => { secret = secret, vm = vm }
    }
  ]...)
}

resource "google_secret_manager_secret" "secret" {
  for_each  = local.secrets
  secret_id = each.key

  labels = local.labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "reader" {
  for_each  = local.grants
  secret_id = google_secret_manager_secret.secret[each.value.secret].id
  role      = "roles/secretmanager.secretAccessor"
  member    = var.members[each.value.vm]
}
