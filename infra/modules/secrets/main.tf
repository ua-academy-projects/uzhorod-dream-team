locals {
  gcp = { for name, vm in var.vms : name => vm if vm.cloud == "gcp" }
}

module "gcp" {
  source = "./gcp"
  count  = length(local.gcp) > 0 ? 1 : 0

  config = var.config
  vms    = local.gcp
}
