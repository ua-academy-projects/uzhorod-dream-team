# Ingress is denied by default; each rule opens one port to one role.
# Targets are service accounts, not tags: a tag can be added by anyone who may edit a VM.
locals {
  firewall_rules = {
    # The UI is reached only through the HTTPS load balancer, never directly.
    edge-allow-lb = {
      network = google_compute_network.edge.id
      ports   = ["5173"]
      sources = local.lb_source_ranges
      targets = ["ui"]
    }
    # The public SSH port is not 22: less noise from bots that scan the standard port.
    edge-allow-ssh-bastion = {
      network = google_compute_network.edge.id
      ports   = [tostring(var.bastion_ssh_port)]
      sources = var.ssh_source_ranges
      targets = ["bastion"]
    }
    edge-allow-iap-bastion = {
      network = google_compute_network.edge.id
      ports   = ["22"]
      sources = [local.iap_cidr]
      targets = ["bastion"]
    }
    private-allow-iap = {
      network = google_compute_network.private.id
      ports   = ["22"]
      sources = [local.iap_cidr]
      targets = ["db", "fetcher", "history"]
    }
    private-allow-ssh-bastion = {
      network = google_compute_network.private.id
      ports   = ["22"]
      sources = ["${local.ip.bastion}/32"]
      targets = ["db", "fetcher", "history", "ui"]
    }
    private-allow-logship = {
      network = google_compute_network.private.id
      ports   = ["22"]
      sources = [local.private_cidr]
      targets = ["db"]
    }
    private-allow-db = {
      network = google_compute_network.private.id
      ports   = var.backend == "redis" ? ["5432", "6379"] : ["5432"]
      sources = ["${local.ip.fetcher}/32", "${local.ip.history}/32"]
      targets = ["db"]
    }
    private-allow-history = {
      network = google_compute_network.private.id
      ports   = ["3001"]
      sources = ["${local.ip.ui}/32"]
      targets = ["history"]
    }
  }
}

resource "google_compute_firewall" "allow" {
  for_each = local.firewall_rules

  name      = each.key
  network   = each.value.network
  direction = "INGRESS"

  source_ranges           = each.value.sources
  target_service_accounts = [for role in each.value.targets : google_service_account.vm[role].email]

  allow {
    protocol = "tcp"
    ports    = each.value.ports
  }
}
