resource "google_compute_instance" "main" {
  project                   = var.google.project_id
  name                      = "${var.name_prefix}-${var.machine.name}"
  zone                      = var.google.zone
  machine_type              = var.machine.machine_type
  tags                      = var.network.tags
  allow_stopping_for_update = true

  boot_disk {
    auto_delete = true
    initialize_params {
      image = var.machine.boot_disk.image
      size  = var.machine.boot_disk.size_gb
      type  = var.machine.boot_disk.type
    }
  }

  dynamic "attached_disk" {
    for_each = var.machine.data_disk == null ? [] : [var.machine.data_disk]
    content {
      source      = google_compute_disk.data[0].id
      device_name = attached_disk.value.device_name
      mode        = "READ_WRITE"
    }
  }

  network_interface {
    subnetwork = var.network.subnetwork_id
    network_ip = var.network.private_ip

    dynamic "access_config" {
      for_each = contains(keys(var.network.public_ips), var.machine.name) ? [1] : []
      content {
        nat_ip       = var.network.public_ips[var.machine.name]
        network_tier = var.network.public_tier
      }
    }
  }

  dynamic "service_account" {
    for_each = var.google.service_account == null ? [] : [var.google.service_account]
    content {
      email  = service_account.value.email
      scopes = ["cloud-platform"]
    }
  }

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
    startup-script         = local.startup_script
  }
}
