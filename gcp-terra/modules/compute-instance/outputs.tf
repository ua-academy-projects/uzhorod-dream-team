output "public_ips" {
  description = "Public IP addresses of instances with public access enabled"
  value = {
    for key, vm in google_compute_instance.instances :
    key => vm.network_interface[0].access_config[0].nat_ip
    if local.instances[key].public_ip
  }
}

output "instance_ids" {
  value = { for key, vm in google_compute_instance.instances : key => vm.id }
}
