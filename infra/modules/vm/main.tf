locals {
  cfg = var.config

  internal_ip = cidrhost(local.cfg.subnet_cidr, local.cfg.host)

  ssh_key = trimspace(file(pathexpand(local.cfg.bastion ? local.cfg.ssh.user_public_key_file : local.cfg.ssh.internal_public_key_file)))
}

resource "google_compute_address" "internal" {
  name         = "${local.cfg.name}-internal"
  region       = local.cfg.region
  subnetwork   = local.cfg.subnetwork_id
  address_type = "INTERNAL"
  address      = local.internal_ip
}

resource "google_compute_address" "external" {
  count  = local.cfg.bastion ? 1 : 0
  name   = "${local.cfg.name}-external"
  region = local.cfg.region
}

resource "google_compute_instance" "vm" {
  name         = local.cfg.name
  zone         = local.cfg.zone
  machine_type = local.cfg.machine_type
  tags         = local.cfg.bastion ? [local.cfg.bastion_tag] : []
  labels       = local.cfg.labels

  boot_disk {
    initialize_params {
      image = local.cfg.image
      size  = local.cfg.disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = local.cfg.subnetwork_id
    network_ip = google_compute_address.internal.address

    dynamic "access_config" {
      for_each = local.cfg.bastion ? [1] : []
      content {
        nat_ip = google_compute_address.external[0].address
      }
    }
  }

  metadata = {
    ssh-keys               = "${local.cfg.ssh.user}:${local.ssh_key}"
    block-project-ssh-keys = "true"
    enable-oslogin         = "FALSE"
  }

  service_account {
    email  = local.cfg.service_account
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  allow_stopping_for_update = true
}
