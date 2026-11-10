resource "google_compute_disk" "data" {
  for_each = { for name, vm in local.vms : name => vm if var.cfg.vm.deploy && vm.data_disk != null }

  project = local.google.project_id
  name    = "${var.cfg.vm.name_prefix}-${each.key}-data"
  zone    = local.google.zone
  size    = each.value.data_disk.size_gb
  type    = each.value.data_disk.type
}
