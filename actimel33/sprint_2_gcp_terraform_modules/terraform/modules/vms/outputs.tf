output "instances" {
  description = "VM name => id, zone, private_ip and port (null when the VM has no port in config.json)"
  value = {
    for name, vm in google_compute_instance.vm : name => {
      id         = vm.id
      zone       = vm.zone
      private_ip = vm.network_interface[0].network_ip
      port       = try(local.machines[name].port, null)
    }
  }
}

output "private_ips" {
  description = "VM name => internal IP"
  value       = { for name, vm in google_compute_instance.vm : name => vm.network_interface[0].network_ip }
}

output "service_account_emails" {
  description = "VM name => email of its service account"
  value       = { for name, account in google_service_account.vm : name => account.email }
}
