locals {
  gcp = var.config.clouds.gcp

  grants = merge([
    for name, vm in var.vms : {
      for role in distinct([for permission in vm.permissions : local.gcp.permissions[permission]]) :
      "${name}/${role}" => { name = name, role = role }
    }
  ]...)
}

resource "google_service_account" "sa" {
  for_each     = var.vms
  project      = var.project_id
  account_id   = "${var.config.prefix}-${each.key}"
  display_name = "VM-${var.config.prefix}-${each.key}"
}

resource "google_project_iam_member" "role" {
  for_each = local.grants
  project  = var.project_id
  role     = each.value.role
  member   = "serviceAccount:${google_service_account.sa[each.value.name].email}"
}
