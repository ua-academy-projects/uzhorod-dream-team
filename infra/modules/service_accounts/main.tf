locals {
  prefix = var.config.prefix
  vms    = var.config.vms

  roles = { for name, vm in local.vms : name => distinct(concat(var.config.vm_defaults.roles, vm.roles)) }

  grants = merge([
    for name, roles in local.roles : {
      for role in roles : "${name}/${role}" => { name = name, role = role }
    }
  ]...)
}

resource "google_service_account" "sa" {
  for_each     = local.vms
  project      = var.project_id
  account_id   = "${local.prefix}-${each.key}"
  display_name = "VM-${local.prefix}-${each.key}"
}

resource "google_project_iam_member" "role" {
  for_each = local.grants
  project  = var.project_id
  role     = each.value.role
  member   = "serviceAccount:${google_service_account.sa[each.value.name].email}"
}
