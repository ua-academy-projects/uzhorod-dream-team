locals {
  backend  = var.config.app.backend
  database = var.config.app.database

  all_machines = { for name, machine in var.config.vms.machines : name => merge(var.config.vms.defaults, machine) }
  vms = [
    for name, machine in local.all_machines : name
    if contains(try(machine.backends, [local.backend]), local.backend) && contains(try(machine.databases, [local.database]), local.database)
  ]

  roles = merge([
    for name, account in var.config.service_accounts : {
      for role in account.roles : "${name}/${role}" => { account = name, role = role }
    }
  ]...)
}

resource "google_service_account" "vm" {
  for_each = toset(local.vms)

  account_id   = "${var.config.vms.service_account_prefix}${each.key}"
  display_name = "Service account of the ${each.key} VM"
}

resource "google_service_account" "account" {
  for_each = var.config.service_accounts

  account_id   = each.key
  display_name = each.value.display_name
}

resource "google_project_iam_member" "role" {
  for_each = local.roles

  project = var.config.project.id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.account[each.value.account].email}"
}
