output "address" {
  description = "Where the application finds PostgreSQL: the managed database's private address (GCP: an IP, AWS: a host name), or the VM's IP (database.type = vm)"
  value = (local.managed
    ? one(concat(module.gcp[*].private_ip, module.aws[*].address))
    : cidrhost(var.config.clouds[coalesce(local.postgres_vm.cloud, local.cloud)].network.subnet_cidr, local.postgres_vm.host)
  )
}
