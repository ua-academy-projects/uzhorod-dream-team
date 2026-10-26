output "bastion_external_ip" {
  value = google_compute_instance.vm["bastion"].network_interface[0].access_config[0].nat_ip
}

output "internal_ips" {
  value = { for k, v in google_compute_instance.vm : k => v.network_interface[0].network_ip }
}

output "ssh_port" {
  value = var.ssh_port
}

output "ssh_user" {
  value = var.ssh_user
}
