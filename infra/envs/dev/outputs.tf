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
  description = "Log in to the bastion; from it: ssh citybikes-db, ssh citybikes-ui, ..."
  value       = one([for vm in module.vm : vm.ssh if vm.bastion])
}

output "database" {
  description = "Which PostgreSQL the application uses (database.type), and its private address"
  value = {
    type     = jsondecode(file("${path.module}/../../config.json")).database.type
    cloudsql = one(module.cloudsql[*].private_ip)
    vm       = one([for vm in module.vm : vm.internal_ip if contains(vm.services, "postgres")])
  }
}
