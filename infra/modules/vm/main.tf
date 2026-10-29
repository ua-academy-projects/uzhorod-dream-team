# One VM: its own service account (identity), a fixed private address, optionally a fixed public
# address, and the metadata (SSH keys, startup script, compose file) that the caller hands in.

locals {
  cfg = var.config
}

resource "google_service_account" "vm" {
  account_id   = local.cfg.name
  display_name = "VM-${local.cfg.name}"
}

resource "google_compute_address" "internal" {
  name         = "${local.cfg.name}-internal"
  region       = local.cfg.region
  subnetwork   = local.cfg.subnetwork_id
  address_type = "INTERNAL"
  address      = local.cfg.internal_ip
}

resource "google_compute_address" "external" {
  count  = local.cfg.public ? 1 : 0
  name   = "${local.cfg.name}-external"
  region = local.cfg.region
}

resource "google_compute_instance" "vm" {
  name         = local.cfg.name
  zone         = local.cfg.zone
  machine_type = local.cfg.machine_type
  tags         = local.cfg.tags
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

    dynamic "access_config" { # public address only where asked
      for_each = local.cfg.public ? [1] : []
      content {
        nat_ip = google_compute_address.external[0].address
      }
    }
  }

  # a change here updates the VM in place (no re-creation); the startup script reads it at boot
  metadata = var.metadata

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"] # what the VM may really do is decided by IAM
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  allow_stopping_for_update = true
}
