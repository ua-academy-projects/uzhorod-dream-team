output "bastion_public_ip" {
  description = "Public IP of Bastion VM"
  value       = google_compute_instance.bastion.network_interface[0].access_config[0].nat_ip
}
