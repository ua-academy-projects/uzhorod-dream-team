locals {
  all_machines = { for name, machine in var.config.machines : name => merge(var.config.defaults, machine) }

  # A VM with backends exists only for those backends; a VM without it always exists.
  machines = {
    for name, machine in local.all_machines : name => machine
    if contains(try(machine.backends, [var.backend]), var.backend)
  }
  data_disks = { for name, machine in local.machines : name => machine.data_disk if can(machine.data_disk) }
  containers = { for name, machine in local.machines : name => machine if can(machine.image_tag) }

  # Built from config: registry_uri is known only after apply.
  registry_host = "${var.project.region}-docker.pkg.dev"
  registry      = "${local.registry_host}/${var.project.id}/${var.registry.repository_id}"

  # Every VM of the config, created or not: templates name hosts in both branches of %{ if }.
  hosts = { for name, machine in local.all_machines : name => "${name}.${machine.zone}.c.${var.project.id}.internal" }

  # A VM gets a startup script when it runs an image or has templates/<vm>.sh.tftpl.
  # A VM with an image but no template fails the plan instead of booting with nothing to run.
  startup_scripts = {
    for name, machine in local.machines : name => join("\n", [
      templatefile("${path.module}/templates/common.sh.tftpl", {}),
      templatefile("${path.module}/templates/${name}.sh.tftpl", {
        image            = can(machine.image_tag) ? "${local.registry}/${name}:${machine.image_tag}" : ""
        registry_host    = local.registry_host
        project_id       = var.project.id
        backend          = var.backend
        hosts            = local.hosts
        database         = var.database
        port             = try(machine.port, null)
        data_disk_device = try("/dev/disk/by-id/google-${machine.data_disk.device_name}", "")
      }),
    ])
    if can(machine.image_tag) || fileexists("${path.module}/templates/${name}.sh.tftpl")
  }
}

module "service_accounts" {
  source = "../iam"

  project_id     = var.project.id
  account_prefix = var.config.service_account_prefix
  machine_roles  = { for name in keys(local.machines) : name => [] }
}

module "data_disks" {
  source   = "../data_disk"
  for_each = local.data_disks

  name   = each.value.name
  zone   = local.machines[each.key].zone
  size   = each.value.size
  type   = each.value.type
  labels = var.project.labels
}

module "compute_instances" {
  source   = "../compute_instance"
  for_each = local.machines

  name         = each.key
  machine_type = each.value.type
  zone         = each.value.zone
  image        = each.value.image
  disk_size    = each.value.disk_size
  disk_type    = each.value.disk_type
  subnetwork   = var.subnets[each.value.subnet]
  labels       = var.project.labels

  # Firewall rules in config.json target these: <vm>-vm, plus internal-vm in the private subnet.
  network_tags = each.value.subnet == "private" ? ["internal-vm", "${each.key}-vm"] : ["${each.key}-vm"]

  attached_disk_id          = try(module.data_disks[each.key].id, null)
  attached_disk_device_name = try(local.data_disks[each.key].device_name, null)

  service_account_email = module.service_accounts.service_account_emails[each.key]
  startup_script        = try(local.startup_scripts[each.key], null)
  has_public_ip         = false
}

# VMs that run a container pull its image.
resource "google_artifact_registry_repository_iam_member" "reader" {
  for_each = local.containers

  location   = var.registry.location
  repository = var.registry.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${module.service_accounts.service_account_emails[each.key]}"
}
