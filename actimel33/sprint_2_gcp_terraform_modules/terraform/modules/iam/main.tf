locals {
  # One binding per machine and role, keyed "machine/role".
  bindings = merge([
    for name, roles in var.machine_roles : {
      for role in roles : "${name}/${role}" => { name = name, role = role }
    }
  ]...)
}

resource "google_service_account" "vm_sa" {
  for_each     = var.machine_roles
  account_id   = "${var.account_prefix}${each.key}"
  display_name = "Service account of the ${each.key} VM"
}

resource "google_project_iam_member" "vm_roles" {
  for_each = local.bindings
  project  = var.project_id
  role     = each.value.role
  member   = "serviceAccount:${google_service_account.vm_sa[each.value.name].email}"
}
