resource "google_compute_instance" "vms" {
  for_each = var.cfg.vm_options.deploy ? local.vms : {}

  project                   = local.google.project_id
  name                      = "${var.cfg.vm_options.name_prefix}-${each.key}"
  zone                      = local.google.zone
  machine_type              = each.value.machine_type
  tags                      = each.value.tags
  allow_stopping_for_update = true

  boot_disk {
    auto_delete = true
    initialize_params {
      image = each.value.boot_disk.image
      size  = each.value.boot_disk.size_gb
      type  = each.value.boot_disk.type
    }
  }

  dynamic "attached_disk" {
    for_each = each.value.data_disk == null ? [] : [each.value.data_disk]
    content {
      source      = google_compute_disk.data[each.key].id
      device_name = attached_disk.value.device_name
      mode        = "READ_WRITE"
    }
  }

  network_interface {
    subnetwork = var.network.subnetwork_id
    network_ip = each.value.private_ip

    dynamic "access_config" {
      for_each = contains(keys(var.network.public_ips), each.key) ? [1] : []
      content {
        nat_ip       = var.network.public_ips[each.key]
        network_tier = var.cfg.network.public_tier
      }
    }
  }

  dynamic "service_account" {
    for_each = contains(keys(var.service_accounts), each.key) ? [var.service_accounts[each.key]] : []
    content {
      email  = service_account.value.email
      scopes = ["cloud-platform"]
    }
  }

  metadata = merge(
    {
      enable-oslogin         = "TRUE"
      block-project-ssh-keys = "TRUE"
    },
    each.key == "bastion" ? { startup-script = local.bastion_startup_script } : {}
  )
}
