resource "google_compute_instance" "main" {
  project                   = var.project_id
  name                      = var.name
  zone                      = var.zone
  machine_type              = var.config.machine_type
  tags                      = var.network.tags
  allow_stopping_for_update = true

  boot_disk {
    auto_delete = true
    initialize_params {
      image = var.config.boot_disk.image
      size  = var.config.boot_disk.size_gb
      type  = var.config.boot_disk.type
    }
  }

  dynamic "attached_disk" {
    for_each = var.config.data_disk == null ? [] : [var.config.data_disk]
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
      for_each = var.network.public_access == null ? [] : [var.network.public_access]
      content {
        nat_ip       = access_config.value.ip
        network_tier = access_config.value.tier
      }
    }
  }

  dynamic "service_account" {
    for_each = var.service_account == null ? [] : [var.service_account]
    content {
      email  = service_account.value.email
      scopes = ["cloud-platform"]
    }
  }

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
    startup-script         = var.startup_script
  }
}
