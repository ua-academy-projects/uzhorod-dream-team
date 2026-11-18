output "address" {
  description = "Where the application finds PostgreSQL: the managed database's private IP, or the VM's (database.type = vm)"
  value = (local.managed
    ? one(module.gcp[*].private_ip)
    : cidrhost(var.config.clouds[coalesce(local.postgres_vm.cloud, local.cloud)].network.subnet_cidr, local.postgres_vm.host)
  )
}
