output "internal_ip" {
  value = google_compute_address.internal.address
}

output "external_ip" {
  value = local.cfg.bastion ? google_compute_address.external[0].address : null
}

output "bastion" {
  value = local.cfg.bastion
}
