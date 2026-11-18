locals {
  labels = { app = var.config.prefix, managed-by = "terraform" }

  readers = {
    for secret in distinct(flatten([for vm in values(var.vms) : vm.secrets])) :
    "${var.config.prefix}-${secret}" => sort([for name, vm in var.vms : name if contains(vm.secrets, secret)])
  }

  grants = merge([
    for secret, names in local.readers : { for name in names : "${secret}/${name}" => { secret = secret, name = name } }
  ]...)
}

resource "google_secret_manager_secret" "secret" {
  for_each  = local.readers
  secret_id = each.key
  labels    = local.labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "reader" {
  for_each  = local.grants
  secret_id = google_secret_manager_secret.secret[each.value.secret].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.vms[each.value.name].identity}"
}
