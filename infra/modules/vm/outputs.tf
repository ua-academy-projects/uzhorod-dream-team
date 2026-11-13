output "name" {
  value = google_compute_instance.this.name
}

output "internal_ip" {
  value = var.ip
}

output "external_ip" {
  value = one(google_compute_address.external[*].address)
}
