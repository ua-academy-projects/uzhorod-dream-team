// TODO remove redundant module wrapper
resource "google_compute_instance" "this" {
  name         = var.name
  machine_type = var.machine_type
  zone         = var.zone
  labels       = var.labels

  tags = var.network_tags

  boot_disk {
    initialize_params {
      image = var.image
      size  = var.disk_size
      type  = var.disk_type
    }
  }

  dynamic "attached_disk" {
    for_each = var.attached_disk_id != null ? [var.attached_disk_id] : []

    content {
      source      = attached_disk.value
      device_name = var.attached_disk_device_name
      mode        = "READ_WRITE"
    }
  }

  metadata_startup_script = var.startup_script

  # SSH access is granted through IAM (OS Login), no keys in metadata.
  metadata = {
    enable-oslogin = "TRUE"
  }

  network_interface {
    subnetwork = var.subnetwork

    dynamic "access_config" {
      for_each = var.has_public_ip ? [1] : []
      content {
        // Ephemeral external IP
      }
    }
  }

  service_account {
    email  = var.service_account_email
    scopes = ["cloud-platform"] # what the VM may do is limited by the roles of its service account
  }
}
