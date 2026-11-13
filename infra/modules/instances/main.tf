resource "google_compute_address" "static" {
  for_each     = { for k, v in var.instances : k => v if v.static_ip }
  name         = "static-${each.key}-ip"
  region       = var.region
  address_type = "EXTERNAL"
}

resource "google_compute_instance" "vm" {
  for_each            = var.instances
  name                = each.key
  zone                = coalesce(each.value.zone, var.defaults.zone)
  machine_type        = coalesce(each.value.machine_type, var.defaults.machine_type)
  tags                = [each.key]
  labels              = each.value.labels # e.g. ops_agent = "nginx" selects the VM for the nginx OS policy (modules/ops_agent)
  deletion_protection = each.value.deletion_protection

  boot_disk {
    initialize_params {
      image = var.defaults.image
      size  = coalesce(each.value.disk_size_gb, var.defaults.disk_size_gb)
    }
  }

  network_interface {
    subnetwork = var.subnet_ids[coalesce(each.value.subnet, var.defaults.subnet)]
    network_ip = each.value.internal_ip

    dynamic "access_config" {
      for_each = coalesce(each.value.external_ip, var.defaults.external_ip) ? [1] : []
      content {
        nat_ip = try(google_compute_address.static[each.key].address, null)
      }
    }
  }

  # ssh keys come from the OS Login profile of whoever has compute.osLogin / osAdminLogin
  # the OS Config agent in the image only works with enable-osconfig; it installs the Ops Agent (modules/ops_agent)
  metadata = {
    enable-oslogin          = "TRUE"
    enable-osconfig         = "TRUE"
    enable-guest-attributes = "TRUE"
  }

  service_account {
    email  = var.service_account_emails[each.key]
    scopes = ["cloud-platform"]
  }
}
