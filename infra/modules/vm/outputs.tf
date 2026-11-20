output "bastion_ip" {
  description = "The only public address"
  value       = local.bastion_ip
}

output "ssh" {
  description = "Log in to a VM through the bastion"
  value = {
    for name, vm in local.built : name => format("ssh -J %s@%s:%d %s@%s",
      var.config.ssh.user, local.bastion_ip, var.config.ssh.bastion_port, var.config.ssh.user, vm.internal_ip)
    if !local.vms[name].bastion
  }
}
