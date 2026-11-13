locals {
  iap_range = "35.235.240.0/20"
}

resource "google_compute_firewall" "ssh_bastion" {
  name          = "${var.config.project.name_prefix}-allow-ssh-bastion"
  network       = var.network_id
  direction     = "INGRESS"
  source_ranges = var.config.access.admin_cidrs
  target_tags   = ["bastion"]

  allow {
    protocol = "tcp"
    ports    = [tostring(var.config.access.ssh_port)]
  }
}

resource "google_compute_firewall" "ssh_internal" {
  name        = "${var.config.project.name_prefix}-allow-ssh-from-bastion"
  network     = var.network_id
  direction   = "INGRESS"
  source_tags = ["bastion"]
  target_tags = ["internal"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "ssh_iap" {
  name          = "${var.config.project.name_prefix}-allow-ssh-from-iap"
  network       = var.network_id
  direction     = "INGRESS"
  source_ranges = [local.iap_range]
  target_tags   = ["internal"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "ssh_iap_bastion" {
  name          = "${var.config.project.name_prefix}-allow-ssh-bastion-from-iap"
  network       = var.network_id
  direction     = "INGRESS"
  source_ranges = [local.iap_range]
  target_tags   = ["bastion"]

  allow {
    protocol = "tcp"
    ports    = [tostring(var.config.access.ssh_port)]
  }
}

resource "google_compute_firewall" "app" {
  for_each = { for r in var.config.firewall : "${r.from}-to-${r.to}" => r }

  name        = "${var.config.project.name_prefix}-allow-${each.key}"
  network     = var.network_id
  direction   = "INGRESS"
  source_tags = [each.value.from]
  target_tags = [each.value.to]

  allow {
    protocol = "tcp"
    ports    = [for p in each.value.ports : try(tostring(tonumber(var.config.app[p])), "0")]
  }
}
