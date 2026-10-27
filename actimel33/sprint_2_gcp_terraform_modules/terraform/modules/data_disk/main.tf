# A separate disk keeps the data when the VM is recreated.
resource "google_compute_disk" "this" {
  name   = var.name
  zone   = var.zone
  size   = var.size
  type   = var.type
  labels = var.labels
}
