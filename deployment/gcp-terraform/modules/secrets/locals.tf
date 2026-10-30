locals {
  vm_access = {
    for name, account in var.service_accounts : name => {
      email   = account.email
      secrets = var.vms[name].secrets
    }
  }
  secrets_to_set = setunion(var.config.passwords, toset(keys(var.revisions)))
  payloads = merge(var.payloads, {
    for name in var.config.passwords : name => ephemeral.random_password.service[name].result
  })
  names = toset(flatten([
    for vm in values(var.vms) : tolist(vm.secrets)
  ]))
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
