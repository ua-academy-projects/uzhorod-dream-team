locals {
  vm_tags       = { for name, vm in var.cfg.vm : name => vm.tags }
  ssh_port      = tostring(var.cfg.vm_options.ssh_port)
  iap_ranges    = ["35.235.240.0/20"]
  bastion_tags  = toset(["bastion"])
  internal_tags = toset(flatten([for vm in var.cfg.vm : vm.tags if !contains(vm.tags, "bastion")]))
}

resource "google_compute_firewall" "ssh_iap" {
  project   = var.cfg.google.project_id
  name      = "${var.cfg.network.name}-ssh-iap"
  network   = google_compute_network.main.id
  direction = "INGRESS"

  source_ranges = local.iap_ranges
  target_tags   = sort(tolist(local.bastion_tags))

  allow {
    protocol = "tcp"
    ports    = [local.ssh_port]
  }
}

resource "google_compute_firewall" "ssh_bastion" {
  project   = var.cfg.google.project_id
  name      = "${var.cfg.network.name}-ssh-bastion"
  network   = google_compute_network.main.id
  direction = "INGRESS"

  source_tags = sort(tolist(local.bastion_tags))
  target_tags = sort(tolist(local.internal_tags))

  allow {
    protocol = "tcp"
    ports    = [local.ssh_port]
  }
}

resource "google_compute_firewall" "ingress" {
  for_each = var.cfg.network.firewall_rules

  project   = var.cfg.google.project_id
  name      = "${var.cfg.network.name}-${each.key}"
  network   = google_compute_network.main.id
  direction = "INGRESS"

  source_ranges = length(each.value.source_ranges) > 0 ? sort(tolist(each.value.source_ranges)) : null
  source_tags   = length(each.value.source_tags) > 0 ? sort(tolist(each.value.source_tags)) : null
  target_tags   = sort(tolist(each.value.target_tags))

  allow {
    protocol = "tcp"
    ports    = sort([for port in each.value.ports : tostring(port)])
  }
}
