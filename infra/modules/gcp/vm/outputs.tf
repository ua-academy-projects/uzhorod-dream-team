output "internal_ip" {
  value = google_compute_address.internal.address
}

output "external_ip" {
  value = local.vm.bastion ? google_compute_address.external[0].address : null
}

output "bastion" {
  value = local.vm.bastion
}

output "placement" {
  description = "Its address and what runs on it"
  value       = "${google_compute_address.internal.address}  ${join(", ", local.vm.services)}"
}

output "services" {
  value = local.vm.services
}
