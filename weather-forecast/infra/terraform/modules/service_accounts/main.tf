resource "google_service_account" "vm" {
  for_each = var.config.service_accounts

  account_id   = "${var.config.project.prefix}-${each.key}"
  display_name = "${var.config.project.prefix} ${each.key} VMs"
}

resource "google_project_iam_member" "vm_role" {
  for_each = merge([
    for account, sa in var.config.service_accounts : {
      for role in lookup(sa, "roles", []) : "${account}/${role}" => { account = account, role = role }
    }
  ]...)

  project = var.project_id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.vm[each.value.account].email}"
}
