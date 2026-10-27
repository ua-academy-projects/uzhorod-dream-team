resource "google_compute_firewall" "allow_iap_to_bastion" {
  name    = "fw-allow-iap-to-bastion"
  network = var.network_name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Trafic only from server Google IAP (35.235.240.0/20 from JSON)
  source_ranges = [var.iap_cidr]

  # rule only for bastion vm
  target_tags = ["bastion-vm"]
}

# Allow SSH from bastion to all internal VMs
resource "google_compute_firewall" "allow_bastion_to_internal" {
  name    = "fw-allow-bastion-to-internal"
  network = var.network_name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Allow trafic, only if it follows from bastion subnetwork (edge_cidr)
  source_ranges = [var.edge_cidr]

  # Apply to isolated instances (db, fetcher, ui)
  target_tags = ["internal-vm"]
}

resource "google_compute_firewall" "allow_lb_health_checks" {
  name    = "fw-allow-lb-health-checks"
  network = var.network_name

  allow {
    protocol = "tcp"
    ports    = ["80", "8080"]
  }

  source_ranges = var.lb_source_ranges
  target_tags   = ["ui-vm"]
}
