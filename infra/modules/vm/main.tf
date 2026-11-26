locals {
  clouds   = var.config.clouds
  defaults = var.config.vms.defaults

  postgres_vm = var.config.database.type == "vm" ? var.config.database.vm : ""

  bastion_clouds  = keys(var.networks)
  tailscale       = length(local.bastion_clouds) > 1
  bastion_secrets = concat(["ssh-host-key"], local.tailscale ? ["tailscale-auth-key"] : [])

  peers = {
    for cloud in local.bastion_clouds : cloud => [for other in local.bastion_clouds : local.clouds[other].network.subnet_cidr if other != cloud]
  }

  placed = merge(
    {
      for name, vm in var.config.vms.instances : "${coalesce(vm.cloud, var.config.default_cloud)}/${name}" => {
        name        = name
        cloud       = coalesce(vm.cloud, var.config.default_cloud)
        host        = vm.host
        bastion     = false
        size        = vm.size
        disk_type   = vm.disk_type
        disk_gb     = vm.disk_gb
        os          = vm.os
        permissions = vm.permissions
        secrets     = distinct(concat(vm.secrets, name == local.postgres_vm ? ["db-password"] : []))
      }
    },
    {
      for cloud in local.bastion_clouds : "${cloud}/bastion" => {
        name        = "bastion"
        cloud       = cloud
        host        = var.config.vms.bastion.host
        bastion     = true
        size        = var.config.vms.bastion.size
        disk_type   = var.config.vms.bastion.disk_type
        disk_gb     = var.config.vms.bastion.disk_gb
        os          = var.config.vms.bastion.os
        permissions = tolist([])
        secrets     = local.bastion_secrets
      }
    },
  )

  vms = {
    for key, vm in local.placed : key => {
      name      = vm.name
      cloud     = vm.cloud
      host      = vm.host
      bastion   = vm.bastion
      tailscale = vm.bastion && local.tailscale
      size      = local.clouds[vm.cloud].vms.sizes[coalesce(vm.size, local.defaults.size)]
      disk_type = local.clouds[vm.cloud].vms.disk_types[coalesce(vm.disk_type, local.defaults.disk_type)]
      disk_gb   = coalesce(vm.disk_gb, local.defaults.disk_gb)
      image     = local.clouds[vm.cloud].vms.os[coalesce(vm.os, local.defaults.os)]
      roles     = distinct([for permission in concat(local.defaults.permissions, vm.permissions) : local.clouds[vm.cloud].iam.permissions[permission]])
      secrets   = vm.secrets
    }
  }
}

module "gcp" {
  source   = "./gcp"
  for_each = { for key, vm in local.vms : vm.name => vm if vm.cloud == "gcp" }

  config      = var.config
  name        = each.key
  vm          = each.value
  region      = local.clouds.gcp.location.regions[var.config.region]
  zone        = local.clouds.gcp.location.zones[var.config.zone]
  subnet_cidr = local.clouds.gcp.network.subnet_cidr
  network_id  = var.networks.gcp.network_id
  subnet_id   = var.networks.gcp.subnet_id
  firewall    = var.networks.gcp.firewall[each.value.bastion ? "bastion" : "vm"]
  secret_ids  = { for secret in each.value.secrets : secret => var.secrets.gcp[secret] }
  peer_cidrs  = local.peers.gcp
}

module "aws" {
  source   = "./aws"
  for_each = { for key, vm in local.vms : vm.name => vm if vm.cloud == "aws" }

  config                 = var.config
  name                   = each.key
  vm                     = each.value
  region                 = local.clouds.aws.location.regions[var.config.region]
  network                = local.clouds.aws.network
  subnets                = { private = var.networks.aws.subnet_id, public = var.networks.aws.public_subnet_id }
  private_route_table_id = var.networks.aws.private_route_table_id
  firewall               = var.networks.aws.firewall[each.value.bastion ? "bastion" : "vm"]
  secret_ids             = { for secret in each.value.secrets : secret => var.secrets.aws[secret] }
  peer_cidrs             = local.peers.aws
}
