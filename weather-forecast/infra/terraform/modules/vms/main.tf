locals {
  vms_with_defaults = {
    for name, vm in var.config.vms.instances : name => merge(var.config.vms.defaults, vm)
  }
}

resource "google_compute_address" "public_ip" {
  for_each = { for name, vm in local.vms_with_defaults : name => vm if vm.public_ip }

  name = "${var.config.project.prefix}-${each.key}-ip"
}

resource "google_compute_disk" "data" {
  for_each = merge([
    for name, vm in local.vms_with_defaults : {
      for i, disk in vm.disks : "${name}-disk-${i + 1}" => {
        size_gb = disk.size_gb
        type    = try(disk.type, vm.disk_type)
      }
    }
  ]...)

  name = "${var.config.project.prefix}-${each.key}"
  type = each.value.type
  size = each.value.size_gb
}

resource "google_compute_instance" "vm" {
  for_each = local.vms_with_defaults

  name                      = "${var.config.project.prefix}-${each.key}"
  machine_type              = each.value.machine_type
  tags                      = each.value.role == "bastion" ? [each.key] : [each.key, "via-bastion"]
  can_ip_forward            = each.value.role == "bastion"
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = each.value.image
      size  = each.value.boot_disk_gb
      type  = each.value.disk_type
    }
  }

  dynamic "attached_disk" {
    for_each = each.value.disks

    content {
      source      = google_compute_disk.data["${each.key}-disk-${attached_disk.key + 1}"].id
      device_name = "disk-${attached_disk.key + 1}"
    }
  }

  network_interface {
    subnetwork = var.subnets[each.value.subnet]
    network_ip = each.value.ip

    dynamic "access_config" {
      for_each = each.value.public_ip ? [1] : []

      content {
        nat_ip = google_compute_address.public_ip[each.key].address
      }
    }
  }

  service_account {
    email  = var.service_accounts[each.value.service_account]
    scopes = ["cloud-platform"]
  }

  metadata = {
    user-data              = local.user_data[each.key]
    block-project-ssh-keys = "true"
  }
}

resource "google_compute_route" "egress" {
  for_each = {
    for name, vm in local.vms_with_defaults : var.config.subnets[vm.subnet].network => name if vm.role == "bastion"
  }

  name              = "${var.config.project.prefix}-${each.key}-egress"
  network           = var.networks[each.key]
  dest_range        = "0.0.0.0/0"
  priority          = 800
  tags              = ["via-bastion"]
  next_hop_instance = google_compute_instance.vm[each.value].self_link
}
