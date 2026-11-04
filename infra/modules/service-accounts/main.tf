locals {
  cfg = var.config

  grants = merge(
    [
      for name, vm in local.cfg.vms : {
        for role in vm.roles : "${name}/${role}" => { name = name, role = role }
      }
  ]...)
}

resource "google_service_account" "sa" {
  for_each     = local.cfg.vms
  project      = local.cfg.project_id
  account_id   = "${local.cfg.prefix}-${each.key}"
  display_name = "VM-${local.cfg.prefix}-${each.key}"
}

resource "google_project_iam_member" "role" {
  for_each = local.grants
  project  = local.cfg.project_id
  role     = each.value.role
  member   = "serviceAccount:${google_service_account.sa[each.value.name].email}"
}
