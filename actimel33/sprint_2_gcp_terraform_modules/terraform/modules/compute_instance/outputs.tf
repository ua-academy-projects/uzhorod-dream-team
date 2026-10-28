output "private_ip" {
  description = "External IP of VM"
  value       = google_compute_instance.this.network_interface[0].network_ip
}

output "instance_id" {
  value = google_compute_instance.this.id
}
