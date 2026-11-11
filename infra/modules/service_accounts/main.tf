locals {
  prefix   = var.config.prefix
  app      = var.config.app
  database = var.config.database

  running = {
    rabbitmq = local.app.queue_backend == "rabbitmq"
    redis    = local.app.cache_backend == "redis"
  }

  postgres_on = local.database.type == "vm" ? local.database.vm : ""
  placed = {
    for name, vm in var.config.vms.instances : name => {
      bastion  = vm.bastion
      services = concat([for s in vm.services : s if lookup(local.running, s, true)], name == local.postgres_on ? ["postgres"] : [])
      secrets  = distinct(concat(vm.secrets, name == local.postgres_on ? ["db-password"] : []))
    }
  }

  vms = { for name, vm in local.placed : name => vm if vm.bastion || length(vm.services) > 0 }

  roles = { for name in keys(local.vms) : name => distinct(concat(var.config.vms.defaults.roles, var.config.vms.instances[name].roles)) }

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
