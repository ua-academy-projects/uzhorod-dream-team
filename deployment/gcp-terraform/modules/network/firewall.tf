locals {
  vm_tags       = { for name, vm in var.cfg.vm.instances : name => vm.tags }
  bastion_port  = tostring(var.cfg.vm.ssh_port)
  internal_port = "22"
  bastion_tags  = toset(["bastion"])
  internal_tags = toset(flatten([for vm in var.cfg.vm.instances : vm.tags if !contains(vm.tags, "bastion")]))
}

resource "google_compute_firewall" "ssh_public" {
  project   = var.cfg.google.project_id
  name      = "${var.cfg.network.name}-ssh-public"
  network   = google_compute_network.main.id
  direction = "INGRESS"

  source_ranges = ["0.0.0.0/0"]
  target_tags   = sort(tolist(local.bastion_tags))

  allow {
    protocol = "tcp"
    ports    = [local.bastion_port]
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
    ports    = [local.internal_port]
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
