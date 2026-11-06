locals {
  google       = var.cfg.google
  deploy_db_vm = !(var.cfg.modes.cloud_sql && var.cfg.modes.postgres_only)
  vms          = { for name, vm in var.cfg.vm : name => vm if name != "db" || local.deploy_db_vm }

  startup_scripts = { for name, vm in local.vms :
    name => templatefile("${path.module}/templates/startup.sh.tftpl", {
      entrypoint = name == "bastion" ? "bastion.sh" : "ssh.sh"
      scripts = {
        for script in toset(name == "bastion" ? ["ssh.sh", "bastion.sh"] : ["ssh.sh"]) :
        script => filebase64("${path.module}/scripts/${script}")
      }
      environment = merge(
        { SSH_PORT = tostring(var.cfg.vm_options.ssh_port) },
        name == "bastion" ? {
          PRIVATE_IP  = vm.private_ip
          DB_IP       = local.deploy_db_vm ? var.cfg.vm.db.private_ip : ""
          FETCHER_IP  = var.cfg.vm.fetcher.private_ip
          HISTORY_IP  = var.cfg.vm.history.private_ip
          UI_IP       = var.cfg.vm.ui.private_ip
          BASTION_SSH = tostring(var.cfg.vm_options.bastion_ssh)
        } : {}
      )
    })
  }
}
