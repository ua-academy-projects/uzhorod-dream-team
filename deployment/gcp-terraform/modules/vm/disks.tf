resource "google_compute_disk" "data" {
  count = var.machine.data_disk == null ? 0 : 1

  project = var.google.project_id
  name    = "${var.name_prefix}-${var.machine.name}-data"
  zone    = var.google.zone
  size    = var.machine.data_disk.size_gb
  type    = var.machine.data_disk.type
}
