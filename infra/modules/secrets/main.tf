locals {
  postgres_vm = var.config.database.type == "vm" ? var.config.database.vm : ""

  readers = {
    for name, vm in var.config.vms.instances : name => {
      cloud   = coalesce(vm.cloud, var.config.default_cloud)
      secrets = distinct(concat(vm.secrets, name == local.postgres_vm ? ["db-password"] : []))
    }
  }

  by_cloud = {
    for cloud in distinct([for vm in values(local.readers) : vm.cloud]) :
    cloud => sort(distinct(flatten([for vm in values(local.readers) : vm.secrets if vm.cloud == cloud])))
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
