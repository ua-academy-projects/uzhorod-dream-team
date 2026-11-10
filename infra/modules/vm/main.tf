locals {
  vm = merge(var.config.vms.defaults, { for key, value in var.config.vms.instances[var.name] : key => value if value != null })

  location = var.config.location
  ssh      = var.config.ssh
  name     = "${var.config.prefix}-${var.name}"
  labels   = { app = var.config.prefix, vm = var.name, managed-by = "terraform" }

  internal_ip = cidrhost(var.config.network.subnet_cidr, local.vm.host)


  ssh_key = trimspace(file(pathexpand(local.vm.bastion ? local.ssh.user_public_key_file : local.ssh.internal_public_key_file)))

  bastion_user_data = <<-EOT
    #cloud-config
    write_files:
      - path: /etc/ssh/sshd_config.d/10-port.conf
        content: |
          Port ${local.ssh.bastion_port}
    runcmd:
      - [systemctl, daemon-reload]
      - [systemctl, restart, ssh.socket]
  EOT
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
      ssh-keys               = "${local.ssh.user}:${local.ssh_key}"
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
}
