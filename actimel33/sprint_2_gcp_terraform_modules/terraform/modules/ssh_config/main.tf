locals {
  hosts = { for name, vm in var.instances : name => vm.private_ip if name != var.config.bastion }
}

resource "local_file" "this" {
  filename        = pathexpand("~/.ssh/config.d/gcp_crypto_modules.conf")
  file_permission = "0600"

  content = templatefile("${path.module}/ssh_config.tftpl", {
    bastion_name = var.config.bastion
    project      = var.project.id
    zone         = var.instances[var.config.bastion].zone
    user         = var.config.user
    hosts        = local.hosts
  })
}
