
resource "google_compute_firewall" "bastion_ssh" {
  name      = "allow-ssh-bastion"
  network   = google_compute_network.analyzer.name
  direction = "INGRESS"
  priority  = 900

  source_ranges = [var.admin_ip_cidr]
  target_tags   = ["bastion-service"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "allow_internal" {
  name      = "allow-internal"
  network   = google_compute_network.analyzer.name
  direction = "INGRESS"
  priority  = 1000

  source_ranges = ["10.10.0.0/24"]

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }

  allow {
    protocol = "icmp"
  }
}

