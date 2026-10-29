# Secret Manager

locals {
  cfg = var.config

  # one permission per (secret, VM). Keyed by VM NAMES: they are known before apply
  grants = merge([
    for secret, vms in local.cfg.readers : {
      for vm in vms : "${secret}/${vm}" => { secret = secret, vm = vm }
    }
  ]...)
}

resource "google_secret_manager_secret" "secret" {
  for_each  = local.cfg.readers
  secret_id = each.key
  labels    = local.cfg.labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "reader" {
  for_each  = local.grants
  secret_id = google_secret_manager_secret.secret[each.value.secret].id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.cfg.members[each.value.vm]
}
