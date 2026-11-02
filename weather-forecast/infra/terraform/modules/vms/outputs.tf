output "internal_ips" {
  value = { for name, vm in google_compute_instance.vm : name => vm.network_interface[0].network_ip }
}

output "external_ips" {
  value = { for name, address in google_compute_address.public_ip : name => address.address }
}
