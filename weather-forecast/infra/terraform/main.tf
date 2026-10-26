resource "google_compute_instance" "vm" {
  for_each       = local.vms
  name           = "${var.prefix}-${each.key}"
  machine_type   = each.value.type
  tags           = each.value.tags
  can_ip_forward = each.key == "bastion"

  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = each.value.disk
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    network_ip = each.value.ip

    dynamic "access_config" {
      for_each = each.key == "bastion" ? [1] : []
      content {
        nat_ip = google_compute_address.bastion.address
      }
    }
  }

  metadata = local.metadata[each.key]
}
