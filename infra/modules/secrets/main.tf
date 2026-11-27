locals {
  postgres_vm = var.config.database.type == "vm" ? var.config.database.vm : ""

  k3s_nodes       = try(var.config.k3s.nodes, {})
  k3s_cloud       = length(local.k3s_nodes) > 0 ? coalesce(var.config.k3s.cloud, var.config.default_cloud) : null
  clouds          = distinct(concat([var.config.default_cloud], [for vm in values(var.config.vms.instances) : coalesce(vm.cloud, var.config.default_cloud)], local.k3s_cloud == null ? [] : [local.k3s_cloud]))
  bastion_secrets = concat(["ssh-host-key"], length(local.clouds) > 1 ? ["tailscale-auth-key"] : [])

  readers = concat(
    [
      for name, vm in var.config.vms.instances : {
        name    = name
        cloud   = coalesce(vm.cloud, var.config.default_cloud)
        secrets = distinct(concat(vm.secrets, name == local.postgres_vm ? ["db-password"] : []))
      }
    ],
    [for cloud in local.clouds : { name = "bastion", cloud = cloud, secrets = local.bastion_secrets }],
  )

  by_cloud = {
    for cloud in local.clouds :
    cloud => sort(distinct(flatten([for reader in local.readers : reader.secrets if reader.cloud == cloud])))
  }
}

module "gcp" {
  source = "./gcp"
  count  = length(lookup(local.by_cloud, "gcp", [])) > 0 ? 1 : 0

  config  = var.config
  secrets = local.by_cloud.gcp
}

module "aws" {
  source = "./aws"
  count  = length(lookup(local.by_cloud, "aws", [])) > 0 ? 1 : 0

  config  = var.config
  secrets = local.by_cloud.aws
}
