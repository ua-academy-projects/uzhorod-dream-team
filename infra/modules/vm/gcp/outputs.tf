output "identity" {
  description = "The service account the VM runs as (modules/secrets lets it read its secrets)"
  value       = google_service_account.vm.email
}

output "id" {
  description = "The instance, for the layers built on it (its self link)"
  value       = google_compute_instance.vm.self_link
}

output "internal_ip" {
  value = google_compute_address.internal.address
}

output "external_ip" {
  value = one(google_compute_instance.vm.network_interface[0].access_config[*].nat_ip)
}
