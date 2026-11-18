locals {
  name   = "${var.config.prefix}-${var.name}"
  labels = { app = var.config.prefix, vm = var.name, managed-by = "terraform" }

  internal_ip = cidrhost(var.subnet_cidr, var.vm.host)

  bastion_user_data = templatefile("${path.module}/bastion.cloud-init.yaml.tftpl", {
    prefix          = var.config.prefix
    ssh_port        = var.config.ssh.bastion_port
    host_key_secret = "${var.config.prefix}-ssh-host-key"
  })
}

data "google_client_config" "current" {}


resource "google_service_account" "vm" {
  account_id   = local.name
  display_name = "VM ${local.name}"
}

resource "google_project_iam_member" "role" {
  for_each = toset(var.vm.roles)
  project  = data.google_client_config.current.project
  role     = each.key
  member   = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_compute_address" "internal" {
  name         = "${local.name}-internal"
  region       = var.region
  subnetwork   = var.subnet_id
  address_type = "INTERNAL"
  address      = local.internal_ip
}

resource "google_compute_address" "external" {
  count  = var.vm.bastion ? 1 : 0
  name   = "${local.name}-external"
  region = var.region
}

resource "terraform_data" "bastion_user_data" {
  input = var.vm.bastion ? local.bastion_user_data : null
}

resource "google_compute_instance" "vm" {
  name         = local.name
  zone         = var.zone
  machine_type = var.vm.size
  tags         = var.firewall
  labels       = local.labels

  boot_disk {
    initialize_params {
      image = var.vm.image
      type  = var.vm.disk_type
      size  = var.vm.disk_gb
    }
  }

  network_interface {
    subnetwork = var.subnet_id
    network_ip = google_compute_address.internal.address

    dynamic "access_config" {
      for_each = var.vm.bastion ? [1] : []
      content {
        nat_ip = google_compute_address.external[0].address
      }
    }
  }

  metadata = merge(
    {
      block-project-ssh-keys = "true"
      enable-oslogin         = "FALSE"
    },
    var.vm.bastion ? { user-data = local.bastion_user_data } : {},
  )

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  allow_stopping_for_update = true

  lifecycle {
    ignore_changes       = [metadata["ssh-keys"]] 
    replace_triggered_by = [terraform_data.bastion_user_data]
  }
}
