resource "google_compute_address" "private" {
  for_each = var.cfg.vm

  project      = var.cfg.google.project_id
  name         = "${var.cfg.network.name}-${each.key}-private"
  region       = var.cfg.google.region
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.private.id
  address      = each.value.private_ip
}

resource "google_compute_address" "public" {
  for_each = { for name, vm in var.cfg.vm : name => vm if vm.public_ip }

  project      = var.cfg.google.project_id
  name         = "${var.cfg.network.name}-${each.key}-public"
  region       = var.cfg.google.region
  address_type = "EXTERNAL"
  network_tier = var.cfg.network.public_tier
}
