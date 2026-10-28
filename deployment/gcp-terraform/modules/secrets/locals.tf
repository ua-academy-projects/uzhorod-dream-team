locals {
  names = toset(flatten([
    for vm in values(var.vm_access) : tolist(vm.secrets)
  ]))
  secret_members = flatten([
    for vm_name, vm in var.vm_access : [
      for secret_name in toset(vm.secrets) : {
        key         = "${vm_name}/${secret_name}"
        secret_name = secret_name
        email       = vm.email
      }
    ]
  ])
}
