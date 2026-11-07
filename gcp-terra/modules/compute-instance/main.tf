locals {
  instances = {
    for key, vm in var.config.instances : key => merge(vm, {
      machine_type           = coalesce(vm.machine_type, var.config.defaults.machine_type)
      public_ip              = coalesce(vm.public_ip, var.config.defaults.public_ip)
      attach_service_account = coalesce(vm.attach_service_account, var.config.defaults.attach_service_account)
      boot_disk = {
        image   = coalesce(vm.boot_disk.image, var.config.defaults.boot_disk.image)
        size_gb = coalesce(vm.boot_disk.size_gb, var.config.defaults.boot_disk.size_gb)
        type    = coalesce(vm.boot_disk.type, var.config.defaults.boot_disk.type)
      }
    })
  }
}

resource "google_compute_address" "static_public_ips" {
  for_each = { for key, vm in local.instances : key => vm if vm.static_public_ip }

  name         = "${each.value.name}-ip"
  project      = var.project_id
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
}

resource "google_compute_instance" "instances" {
  for_each = local.instances

  name                      = each.value.name
  project                   = var.project_id
  zone                      = var.zone
  machine_type              = each.value.machine_type
  allow_stopping_for_update = true
  tags                      = each.value.tags

  boot_disk {
    initialize_params {
      image = each.value.boot_disk.image
      size  = each.value.boot_disk.size_gb
      type  = each.value.boot_disk.type
    }
  }

  network_interface {
    subnetwork = var.subnet_id
    network_ip = each.value.network_ip

    dynamic "access_config" {
      for_each = each.value.public_ip ? [true] : []
      content {
        nat_ip       = each.value.static_public_ip ? google_compute_address.static_public_ips[each.key].address : null
        network_tier = "PREMIUM"
      }
    }
  }

  dynamic "service_account" {
    for_each = each.value.attach_service_account ? [var.service_account_emails[each.key]] : []
    content {
      email  = service_account.value
      scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    }
  }

  metadata = each.value.startup.type == "none" ? {} : {
    startup-script = each.value.startup.type == "bastion" ? templatefile(
      "${path.module}/scripts/bastion.sh.tftpl", { ssh_port = each.value.startup.ssh_port }
      ) : templatefile("${path.module}/scripts/vm-startup.sh.tftpl", {
        startup_exports = join("\n", [for name, value in {
          APP_BACKEND              = var.config.application.app_backend
          DATABASE_PROVIDER        = var.database.provider
          DATABASE_HOST            = var.database.host
          DATABASE_NAME            = var.database.name
          INSTANCE_CONNECTION_NAME = var.database.connection_name
          SERVICE_ROLE             = each.value.startup.service_role
          PROJECT_ID               = var.project_id
          ENV_SECRET_ID            = var.env_secret_ids[each.key]
          IP_HTTPS                 = tostring(each.value.startup.ip_https)
          REPO_URL                 = var.config.application.repo_url
          REPO_REF                 = var.config.application.repo_branch
        } : "export ${name}='${replace(value, "'", "'\"'\"'")}'"])
    })
  }

  lifecycle {
    ignore_changes = [metadata["ssh-keys"]]
  }
}
