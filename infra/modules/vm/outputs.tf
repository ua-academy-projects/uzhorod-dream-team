locals {
  built = merge(
    { for name, vm in module.gcp : "gcp/${name}" => vm },
    { for name, vm in module.aws : "aws/${name}" => vm },
  )

  bastion_ips = { for key, vm in local.built : local.vms[key].cloud => vm.external_ip if local.vms[key].bastion }
}

output "bastion_ips" {
  description = "cloud => its bastion's public address: the only public addresses"
  value       = local.bastion_ips
}

output "ssh" {
  description = "Log in to a VM through the bastion of its cloud"
  value = {
    for key, vm in local.built : local.vms[key].name => format(
      "ssh -J %s@%s:%d %s@%s",
      var.config.ssh.user, local.bastion_ips[local.vms[key].cloud], var.config.ssh.bastion_port,
      var.config.ssh.user, vm.internal_ip,
    ) if !local.vms[key].bastion
  }
}

output "instances" {
  description = "VM name => { cloud, id, internal_ip }, the bastions left out: for the layers built on the VMs (the k3s cluster)"
  value = {
    for key, vm in local.built : local.vms[key].name => { cloud = local.vms[key].cloud, id = vm.id, internal_ip = vm.internal_ip }
    if !local.vms[key].bastion
  }
}