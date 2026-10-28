output "name" {
  value = google_compute_instance.main.name
}

output "instance_id" {
  value = google_compute_instance.main.instance_id
}

output "zone" {
  value = google_compute_instance.main.zone
}

output "private_ip" {
  value = google_compute_instance.main.network_interface[0].network_ip
}

output "public_ip" {
  value = try(google_compute_instance.main.network_interface[0].access_config[0].nat_ip, null)
}

output "data_disk_id" {
  value = try(google_compute_disk.data[0].id, null)
}
