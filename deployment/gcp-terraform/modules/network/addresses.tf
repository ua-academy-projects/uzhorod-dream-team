resource "google_compute_address" "private" {
  for_each = var.vms

  project      = var.project_id
  name         = "${var.config.name}-${each.key}-private"
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.private.id
  address      = each.value.private_ip
}

resource "google_compute_address" "public" {
  for_each = { for name, vm in var.vms : name => vm if vm.public_ip }

  project      = var.project_id
  name         = "${var.config.name}-${each.key}-public"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = var.config.public_network_tier
}
