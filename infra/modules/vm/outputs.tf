output "bastion_ip" {
  description = "The only public address"
  value       = one([for vm in module.gcp : vm.external_ip if vm.external_ip != null])
}

output "ssh" {
  description = "Log in to a VM through the bastion"
  value = {
    for name, vm in module.gcp : name => format("ssh -J %s@%s:%d %s@%s",
      var.config.ssh.user, one([for b in module.gcp : b.external_ip if b.external_ip != null]), var.config.ssh.bastion_port,
    var.config.ssh.user, vm.internal_ip)
    if !local.vms[name].bastion
  }
}
