locals {
  cfg     = jsondecode(file(startswith(var.config_file, "/") ? var.config_file : "${path.module}/${var.config_file}"))
  bastion = module.cloud_init.bastion
}
