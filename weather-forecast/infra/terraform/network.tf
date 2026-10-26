resource "google_compute_network" "vpc" {
  name                    = "${var.prefix}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.prefix}-subnet"
  ip_cidr_range = "192.168.56.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
}

resource "google_compute_address" "bastion" {
  name   = "${var.prefix}-bastion-ip"
  region = var.region
}

resource "google_compute_route" "via_bastion" {
  name                   = "${var.prefix}-default-via-bastion"
  network                = google_compute_network.vpc.name
  dest_range             = "0.0.0.0/0"
  priority               = 800
  tags                   = ["via-bastion"]
  next_hop_instance      = google_compute_instance.vm["bastion"].name
  next_hop_instance_zone = var.zone
}
