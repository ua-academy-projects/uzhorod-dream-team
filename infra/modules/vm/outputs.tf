output "internal_ip" {
  value = google_compute_address.internal.address
}

output "external_ip" {
  value = local.cfg.public ? google_compute_address.external[0].address : null
}

output "member" {
  description = "The VM's service account as an IAM member"
  value       = "serviceAccount:${google_service_account.vm.email}"
}
