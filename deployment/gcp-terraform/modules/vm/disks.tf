resource "google_compute_disk" "data" {
  count = var.config.data_disk == null ? 0 : 1

  project = var.project_id
  name    = "${var.name}-data"
  zone    = var.zone
  size    = var.config.data_disk.size_gb
  type    = var.config.data_disk.type
}
