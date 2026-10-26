resource "google_compute_firewall" "ssh_bastion" {
  name          = "${var.prefix}-allow-ssh-bastion"
  network       = google_compute_network.vpc.name
  source_ranges = [var.my_ip_cidr]
  target_tags   = ["bastion"]

  allow {
    protocol = "tcp"
    ports    = [tostring(var.ssh_port)]
  }
}

resource "google_compute_firewall" "gateway_from_internal" {
  name        = "${var.prefix}-allow-gateway-from-internal"
  network     = google_compute_network.vpc.name
  source_tags = ["via-bastion"]
  target_tags = ["bastion"]

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
}

locals {
  internal_rules = {
    ssh-internal = { from = ["bastion"], to = ["via-bastion"], port = tostring(var.ssh_port) }
    postgres     = { from = ["history", "fetcher"], to = ["db"], port = "5432" }
    rabbit       = { from = ["history", "fetcher"], to = ["db"], port = "5672" }
    redis        = { from = ["history"], to = ["db"], port = "6379" }
    history-api  = { from = ["ui"], to = ["history"], port = "8002" }
    ui-http      = { from = ["bastion"], to = ["ui"], port = "80" }
  }
}

resource "google_compute_firewall" "internal" {
  for_each    = local.internal_rules
  name        = "${var.prefix}-allow-${each.key}"
  network     = google_compute_network.vpc.name
  source_tags = each.value.from
  target_tags = each.value.to

  allow {
    protocol = "tcp"
    ports    = [each.value.port]
  }
}
