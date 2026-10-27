output "id" {
  description = "ID of the disk, for attached_disk of the VM"
  value       = google_compute_disk.this.id
}
