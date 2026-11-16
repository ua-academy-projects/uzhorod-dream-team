output "vms" {
  description = "The VMs to build (the bastion, and every VM that runs something), each with everything a cloud needs to build it"
  value       = { for name, vm in local.config_vms : name => vm if vm.bastion || length(vm.services) > 0 }
}
