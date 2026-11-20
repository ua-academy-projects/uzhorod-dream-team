output "addresses" {
  description = "name => { cloud, internal_ip, external_ip (the bastion only) }"
  value = {
    for name, vm in local.built : name => { cloud = local.vms[name].cloud, internal_ip = vm.internal_ip, external_ip = vm.external_ip }
  }
}

output "ssh" {
  description = "Log in to a VM through the bastion of its cloud"
  value = {
    for name, vm in local.built : name => format("ssh -J %s@%s:%d %s@%s",
      var.config.ssh.user, var.bastions[local.vms[name].cloud].external_ip, var.config.ssh.bastion_port,
      var.config.ssh.user, vm.internal_ip)
    if !local.vms[name].bastion
  }
}