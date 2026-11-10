locals {
  project_id = var.cfg.google.project_id
  vm_access = {
    for name, account in var.service_accounts : name => {
      email   = account.email
      secrets = var.cfg.vm.instances[name].secrets
    }
  }
  passwords      = var.cfg.secrets.passwords
  secrets_to_set = setunion(local.passwords, toset(keys(var.revisions)))
  payloads = merge(var.payloads, {
    for name in local.passwords : name => ephemeral.random_password.service[name].result
  })
  names = setunion(local.passwords, toset(flatten([
    for vm in values(var.cfg.vm.instances) : tolist(vm.secrets)
  ])))
  secret_members = flatten([
    for vm_name, vm in local.vm_access : [
      for secret_name in toset(vm.secrets) : {
        key         = "${vm_name}/${secret_name}"
        secret_name = secret_name
        email       = vm.email
      }
    ]
  ])
}
