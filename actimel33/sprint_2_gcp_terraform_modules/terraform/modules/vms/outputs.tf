output "instances" {
  description = "VM name => id, zone, private_ip and port (null when the VM has no port in config.json)"
  value = {
    for name, vm in module.compute_instances : name => {
      id         = vm.instance_id
      zone       = local.machines[name].zone
      private_ip = vm.private_ip
      port       = try(local.machines[name].port, null)
    }
  }
}

output "private_ips" {
  description = "VM name => internal IP"
  value       = { for name, vm in module.compute_instances : name => vm.private_ip }
}

output "service_account_emails" {
  description = "VM name => email of its service account"
  value       = module.service_accounts.service_account_emails
}
