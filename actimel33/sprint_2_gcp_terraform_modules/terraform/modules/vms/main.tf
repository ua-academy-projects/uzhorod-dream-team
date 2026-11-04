locals {
  backend      = var.config.app.backend
  all_machines = { for name, machine in var.config.vms.machines : name => merge(var.config.vms.defaults, machine) }

  machines = {
    for name, machine in local.all_machines : name => machine
    if contains(try(machine.backends, [local.backend]), local.backend)
  }
  data_disks = { for name, machine in local.machines : name => machine.data_disk if can(machine.data_disk) }
  containers = { for name, machine in local.machines : name => machine if can(machine.image_tag) }
}

resource "google_service_account" "vm" {
  for_each = local.machines

  account_id   = "${var.config.vms.service_account_prefix}${each.key}"
  display_name = "Service account of the ${each.key} VM"
}

resource "google_compute_disk" "data" {
  for_each = local.data_disks

  name   = each.value.name
  zone   = local.machines[each.key].zone
  size   = each.value.size
  type   = each.value.type
  labels = var.config.project.labels
}

resource "google_compute_instance" "vm" {
  for_each = local.machines

  name         = each.key
  machine_type = each.value.type
  zone         = each.value.zone
  labels       = var.config.project.labels

  # Firewall rules in config.json
  tags = each.value.subnet == "private" ? ["internal-vm", "${each.key}-vm"] : ["${each.key}-vm"]

  boot_disk {
    initialize_params {
      image = each.value.image
      size  = each.value.disk_size
      type  = each.value.disk_type
    }
  }

  dynamic "attached_disk" {
    for_each = contains(keys(local.data_disks), each.key) ? [local.data_disks[each.key]] : []

    content {
      source      = google_compute_disk.data[each.key].id
      device_name = attached_disk.value.device_name
      mode        = "READ_WRITE"
    }
  }

  # SSH access is granted through IAM.
  metadata = {
    enable-oslogin = "TRUE"
  }

  network_interface {
    subnetwork = var.subnets[each.value.subnet]
  }

  service_account {
    email  = google_service_account.vm[each.key].email
    scopes = ["cloud-platform"]
  }
}

resource "google_artifact_registry_repository_iam_member" "reader" {
  for_each = local.containers

  location   = var.registry.location
  repository = var.registry.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.vm[each.key].email}"
}
