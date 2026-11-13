locals {
  vm           = var.config.vms[var.key]
  name         = "${var.config.project.name_prefix}-${var.key}"
  tags         = concat([var.key], local.vm.bastion ? ["bastion"] : ["internal"])
  machine_type = coalesce(local.vm.machine_type, var.config.vm_defaults.machine_type)
  image        = coalesce(local.vm.image, var.config.vm_defaults.image)
  disk_type    = coalesce(local.vm.disk_type, var.config.vm_defaults.disk_type)
  disk_gb      = coalesce(local.vm.disk_gb, var.config.vm_defaults.disk_gb)
}

resource "google_compute_address" "external" {
  count = local.vm.bastion ? 1 : 0

  name         = "${local.name}-external"
  region       = var.config.project.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
}

resource "google_compute_instance" "this" {
  name                      = local.name
  machine_type              = local.machine_type
  zone                      = var.config.project.zone
  tags                      = local.tags
  allow_stopping_for_update = true

  labels = {
    iss-prefix = var.config.project.name_prefix
    iss-key    = var.key
    iss-role   = local.vm.bastion ? "bastion" : "app"
  }

  boot_disk {
    auto_delete = true

    initialize_params {
      image = local.image
      size  = local.disk_gb
      type  = local.disk_type
    }
  }

  network_interface {
    subnetwork = var.subnetwork_id
    network_ip = var.ip

    dynamic "access_config" {
      for_each = google_compute_address.external

      content {
        nat_ip       = access_config.value.address
        network_tier = "PREMIUM"
      }
    }
  }

  metadata = {
    enable-oslogin         = "FALSE"
    block-project-ssh-keys = "TRUE"
    user-data              = var.user_data
  }

  dynamic "service_account" {
    for_each = var.service_account == null ? [] : [var.service_account]

    content {
      email  = service_account.value
      scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    }
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  lifecycle {
    ignore_changes = [
      metadata["ssh-keys"],
      boot_disk[0].initialize_params[0].image,
    ]
  }
}
