locals {
  defaults = var.config.vms.defaults

  running = {
    rabbitmq = var.config.app.queue_backend == "rabbitmq"
    redis    = var.config.app.cache_backend == "redis"
  }

  postgres_vm = var.config.database.type == "vm" ? var.config.database.vm : ""

  # Every VM of config.json: vms.defaults filled in, the switches applied
  config_vms = {
    for name, vm in var.config.vms.instances : name => {
      host          = vm.host
      bastion       = vm.bastion
      size          = coalesce(vm.size, local.defaults.size)
      os            = coalesce(vm.os, local.defaults.os)
      disk_gb       = coalesce(vm.disk_gb, local.defaults.disk_gb)
      cloud_logging = coalesce(vm.cloud_logging, local.defaults.cloud_logging)
      permissions   = distinct(concat(local.defaults.permissions, vm.permissions))

      services = concat(
        [for service in vm.services : service if lookup(local.running, service, true)],
        name == local.postgres_vm ? ["postgres"] : [],
      )
      secrets = distinct(concat(vm.secrets, name == local.postgres_vm ? ["db-password"] : []))
    }
  }
}
