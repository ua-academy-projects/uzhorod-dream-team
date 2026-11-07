locals {
  vm       = var.config.vms[var.name]
  defaults = var.config.vm_defaults
  location = var.config.location
  ssh      = var.config.ssh

  machine_type = coalesce(local.vm.machine_type, local.defaults.machine_type)
  disk_size_gb = coalesce(local.vm.disk_size_gb, local.defaults.disk_size_gb)
  image        = coalesce(local.vm.image, local.defaults.image)

  name   = "${var.config.prefix}-${var.name}"
  labels = merge(var.labels, { vm = var.name })

  internal_ip = cidrhost(var.config.network.subnet_cidr, local.vm.host)

  ssh_key = trimspace(file(pathexpand(local.vm.bastion ? local.ssh.user_public_key_file : local.ssh.internal_public_key_file)))
}

resource "google_compute_address" "internal" {
  name         = "${local.name}-internal"
  region       = local.location.region
  subnetwork   = var.subnetwork_id
  address_type = "INTERNAL"
  address      = local.internal_ip
}

resource "google_compute_address" "external" {
  count  = local.vm.bastion ? 1 : 0
  name   = "${local.name}-external"
  region = local.location.region
}

resource "google_compute_instance" "vm" {
  name         = local.name
  zone         = local.location.zone
  machine_type = local.machine_type
  tags         = local.vm.bastion ? [var.bastion_tag] : []
  labels       = local.labels

  boot_disk {
    initialize_params {
      image = local.image
      size  = local.disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = var.subnetwork_id
    network_ip = google_compute_address.internal.address

    dynamic "access_config" {
      for_each = local.vm.bastion ? [1] : []
      content {
        nat_ip = google_compute_address.external[0].address
      }
    }
  }

  metadata = {
    ssh-keys               = "${local.ssh.user}:${local.ssh_key}"
    block-project-ssh-keys = "true"
    enable-oslogin         = "FALSE"
  }

  service_account {
    email  = var.service_account
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  allow_stopping_for_update = true
}
