locals {
  google       = var.cfg.google
  deploy_db_vm = !(var.cfg.modes.cloud_sql && var.cfg.modes.postgres_only)
  vms          = { for name, vm in var.cfg.vm : name => vm if name != "db" || local.deploy_db_vm }

  bastion_startup_script = templatefile("${path.module}/templates/startup.sh.tftpl", {
    script = filebase64("${path.module}/scripts/bastion.sh")
    environment = {
      SSH_PORT    = tostring(var.cfg.vm_options.ssh_port)
      PRIVATE_IP  = var.cfg.vm.bastion.private_ip
      DB_IP       = local.deploy_db_vm ? var.cfg.vm.db.private_ip : ""
      FETCHER_IP  = var.cfg.vm.fetcher.private_ip
      HISTORY_IP  = var.cfg.vm.history.private_ip
      UI_IP       = var.cfg.vm.ui.private_ip
      BASTION_SSH = tostring(var.cfg.vm_options.bastion_ssh)
    }
  })
}
