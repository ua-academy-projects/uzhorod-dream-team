locals {
  vms = {
    bastion = { ip = "192.168.56.10", type = "e2-micro", disk = 10, tags = ["bastion"] }
    db      = { ip = "192.168.56.11", type = "e2-small", disk = 20, tags = ["db", "via-bastion"] }
    fetcher = { ip = "192.168.56.12", type = "e2-small", disk = 10, tags = ["fetcher", "via-bastion"] }
    history = { ip = "192.168.56.13", type = "e2-small", disk = 12, tags = ["history", "via-bastion"] }
    ui      = { ip = "192.168.56.14", type = "e2-micro", disk = 10, tags = ["ui", "via-bastion"] }
  }
}

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
      content {}
    }
  }

  metadata = {
    ssh-keys = "${var.ssh_user}:${trimspace(file(pathexpand(var.ssh_public_key_path)))}"
  }
}
