output "internal_ips" {
  value = { for k, v in google_compute_instance.vm : k => v.network_interface[0].network_ip }
}

# every public address, including ephemeral ones (bastion); instances without an access_config are skipped
output "public_ips" {
  value = {
    for k, v in google_compute_instance.vm : k => v.network_interface[0].access_config[0].nat_ip
    if length(v.network_interface[0].access_config) > 0
  }
}

output "external_ips" {
  value = { for k, a in google_compute_address.static : k => a.address }
}
