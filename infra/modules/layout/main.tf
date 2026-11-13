locals {
  db_needed = anytrue([
    var.config.app.POSTGRES_BACKEND == "container",
    var.config.app.QUEUE_BACKEND == "rabbitmq",
    var.config.app.SESSION_BACKEND == "redis",
  ])
  vm_keys = toset([for k in keys(var.config.vms) : k if k != "db" || local.db_needed])
}
