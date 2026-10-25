locals {
  registry = "${google_artifact_registry_repository.crypto.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.crypto.repository_id}"

  # The bastion needs no images.
  deployed = { for name, machine in local.machines : name => machine if name == "bastion" || var.image_tag != null }

  script_vars = {
    project_id          = var.project_id
    backend             = var.backend
    admin_user          = var.admin_user
    console_user        = var.console_user
    bastion_ssh_port    = var.bastion_ssh_port
    registry            = local.registry
    image_tag           = coalesce(var.image_tag, "none")
    ip                  = local.ip
    private_cidr        = local.private_cidr
    iap_cidr            = local.iap_cidr
    jump_authorized_key = local.jump_authorized_key
    logship_public_keys = { for name in local.services : name => trimspace(tls_private_key.logship[name].public_key_openssh) }

    logship_script = file("${path.module}/../logship/logship.sh")
    logsink_script = file("${path.module}/../logship/logsink.sh")
  }

  # Shared functions first, then the role's own steps.
  startup_scripts = {
    for name in keys(local.deployed) : name => templatefile(
      "${path.module}/templates/${name}.sh.tftpl",
      merge(local.script_vars, {
        common = templatefile("${path.module}/templates/common.sh.tftpl", merge(local.script_vars, { role = name }))
      })
    )
  }
}

# Postgres and Redis data outlive the db VM: a deploy replaces the VM, not this disk.
resource "google_compute_disk" "data" {
  name = "crypto-db-data"
  type = "pd-balanced"
  size = 10
  zone = var.zone

  depends_on = [google_project_service.this]
}

# Metadata SSH keys instead of OS Login: the jump key needs restrict/permitopen/command
# options in authorized_keys, which OS Login cannot express.
# The one public IP belongs to the bastion.
#trivy:ignore:GCP-0036
#trivy:ignore:GCP-0031
resource "google_compute_instance" "vm" {
  for_each = local.deployed

  name         = each.key
  machine_type = each.value.type
  labels       = { role = each.key }

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = 10
      type  = "pd-balanced"
    }
  }

  # The edge NIC goes first.
  dynamic "network_interface" {
    for_each = each.value.edge_ip == null ? [] : [each.value.edge_ip]
    content {
      subnetwork = google_compute_subnetwork.edge.id
      network_ip = network_interface.value

      # Only the bastion is public.
      dynamic "access_config" {
        for_each = each.key == "bastion" ? [1] : []
        content {}
      }
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.private.id
    network_ip = each.value.private_ip
  }

  # Appears in the VM as /dev/disk/by-id/google-data.
  dynamic "attached_disk" {
    for_each = each.key == "db" ? [google_compute_disk.data.id] : []
    content {
      source      = attached_disk.value
      device_name = "data"
    }
  }

  service_account {
    email  = google_service_account.vm[each.key].email
    scopes = ["cloud-platform"] # access is limited by IAM
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true # Virtual Trusted Platform Module
    enable_integrity_monitoring = true
  }

  metadata = {
    # Keys per VM; the bastion gets none: nobody logs in there but jump.
    block-project-ssh-keys = "true"
    ssh-keys               = each.key == "bastion" ? "" : "${var.admin_user}:${local.ssh_public_key}"
  }

  # A new image_tag changes the script, a deploy replaces the VM.
  metadata_startup_script = local.startup_scripts[each.key]

  allow_stopping_for_update = true

  lifecycle {
    # The Console SSH button adds short-lived keys here.
    ignore_changes = [metadata["ssh-keys"]]
  }

  depends_on = [
    google_compute_router_nat.nat,
    google_secret_manager_secret_version.password,
    google_secret_manager_secret_version.logship_key,
    google_secret_manager_secret_iam_member.reader,
    google_artifact_registry_repository_iam_member.vm_reader,
  ]
}
