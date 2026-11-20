locals {
  clouds   = var.config.clouds
  defaults = var.config.vms.defaults

  postgres_vm = var.config.database.type == "vm" ? var.config.database.vm : ""

  placed = { for name, vm in var.config.vms.instances : name => merge(vm, { cloud = coalesce(vm.cloud, var.config.default_cloud) }) }

  vms = {
    for name, vm in local.placed : name => {
      cloud     = vm.cloud
      host      = vm.host
      bastion   = vm.bastion
      size      = local.clouds[vm.cloud].vms.sizes[coalesce(vm.size, local.defaults.size)]
      disk_type = local.clouds[vm.cloud].vms.disk_types[coalesce(vm.disk_type, local.defaults.disk_type)]
      disk_gb   = coalesce(vm.disk_gb, local.defaults.disk_gb)
      image     = local.clouds[vm.cloud].vms.os[coalesce(vm.os, local.defaults.os)]
      roles     = distinct([for permission in concat(local.defaults.permissions, vm.permissions) : local.clouds[vm.cloud].iam.permissions[permission]])

      secrets = distinct(concat(vm.secrets, name == local.postgres_vm ? ["db-password"] : []))
    }
  }
}

module "gcp" {
  source   = "./gcp"
  for_each = { for name, vm in local.vms : name => vm if vm.cloud == "gcp" }

  config      = var.config
  name        = each.key
  vm          = each.value
  region      = local.clouds.gcp.location.regions[var.config.region]
  zone        = local.clouds.gcp.location.zones[var.config.zone]
  subnet_cidr = local.clouds.gcp.network.subnet_cidr
  subnet_id   = var.networks.gcp.subnet_id
  firewall    = var.networks.gcp.firewall[each.value.bastion ? "bastion" : "vm"]
  secret_ids  = { for secret in each.value.secrets : secret => var.secrets.gcp[secret] }
}
