output "bastion_ip" {
  description = "The only public address"
  value       = one([for vm in module.vm : vm.external_ip if vm.bastion])
}

output "placement" {
  description = "Which VM runs what, at which address"
  value       = { for name, vm in module.vm : name => vm.placement }
}

output "ssh" {
  description = "Log in to a VM through the bastion (the bastion itself has no shell). First: ansible-playbook citybikes.infra.access"
  value = {
    for name, vm in module.vm : name => format("ssh -J %s@%s:%d %s@%s",
      var.config.ssh.user, one([for b in module.vm : b.external_ip if b.bastion]), var.config.ssh.bastion_port,
    var.config.ssh.user, vm.internal_ip)
    if !vm.bastion
  }
}

output "database" {
  description = "Which PostgreSQL the application uses (database.type), and its private address"
  value = {
    type    = var.config.database.type
    managed = one(module.database[*].private_ip)
    vm      = one([for vm in module.vm : vm.internal_ip if contains(vm.services, "postgres")])
  }
}

output "dashboard_url" {
  description = "The CityBikes overview dashboard in the Cloud console"
  value       = module.monitoring.dashboard_url
}
