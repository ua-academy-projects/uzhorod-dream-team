output "bastion_ip" {
  description = "The only public address"
  value       = one([for vm in module.vm : vm.external_ip if vm.bastion])

  precondition {
    condition     = length([for vm in module.vm : vm if vm.bastion]) == 1
    error_message = "config.json: exactly one VM of vms.instances must have \"bastion\": true."
  }
}

output "placement" {
  description = "Which VM runs what, at which address"
  value       = { for name, vm in module.vm : name => vm.placement }
}

output "ssh" {
  description = "Log in to a VM through the bastion (the bastion itself has no shell). First: ansible-playbook citybikes.infra.access"
  value = {
    for name, vm in module.vm : name => format("ssh -J %s@%s:%d %s@%s",
      jsondecode(file("${path.module}/../../config.json")).ssh.user,
      one([for b in module.vm : b.external_ip if b.bastion]),
      jsondecode(file("${path.module}/../../config.json")).ssh.bastion_port,
      jsondecode(file("${path.module}/../../config.json")).ssh.user,
    vm.internal_ip)
    if !vm.bastion
  }
}

output "database" {
  description = "Which PostgreSQL the application uses (database.type), and its private address"
  value = {
    type     = jsondecode(file("${path.module}/../../config.json")).database.type
    cloudsql = one(module.cloudsql[*].private_ip)
    vm       = one([for vm in module.vm : vm.internal_ip if contains(vm.services, "postgres")])
  }
}
