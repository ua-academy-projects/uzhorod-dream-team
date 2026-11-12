locals {
  vm = merge(var.config.vms.defaults, { for key, value in var.config.vms.instances[var.name] : key => value if value != null })

  location = var.config.location
  ssh      = var.config.ssh
  name     = "${var.config.prefix}-${var.name}"
  labels   = { app = var.config.prefix, vm = var.name, managed-by = "terraform" }

  internal_ip = cidrhost(var.config.network.subnet_cidr, local.vm.host)

  bastion_user_data = templatefile("${path.module}/bastion.cloud-init.yaml.tftpl", {
    prefix          = var.config.prefix
    name            = local.name
    zone            = local.location.zone
    ssh_port        = local.ssh.bastion_port
    host_key_secret = "${var.config.prefix}-ssh-host-key"
  })
}

resource "google_compute_address" "internal" {
  name         = "${local.name}-internal"
  region       = local.location.region
  subnetwork   = var.subnetwork_id
  address_type = "INTERNAL"
  address      = local.internal_ip
}

resource "google_compute_address" "external" {
  count  = local.vm.bastion ? 1 : 0
  name   = "${local.name}-external"
  region = local.location.region
}

resource "terraform_data" "bastion_user_data" {
  input = local.vm.bastion ? local.bastion_user_data : null
}

resource "google_compute_instance" "vm" {
  name         = local.name
  zone         = local.location.zone
  machine_type = local.vm.machine_type
  tags         = local.vm.bastion ? [var.bastion_tag] : []
  labels       = local.labels

  boot_disk {
    initialize_params {
      image = local.vm.image
      size  = local.vm.disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = var.subnetwork_id
    network_ip = google_compute_address.internal.address

    dynamic "access_config" {
      for_each = local.vm.bastion ? [1] : []
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
    local.vm.bastion ? { user-data = local.bastion_user_data } : {},
  )

  service_account {
    email  = var.service_account
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  allow_stopping_for_update = true

  lifecycle {
    ignore_changes       = [metadata["ssh-keys"]] # the keys belong to Ansible
    replace_triggered_by = [terraform_data.bastion_user_data]
  }
}
