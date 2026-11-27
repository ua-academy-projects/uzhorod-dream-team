output "address" {
  description = "Where the application finds PostgreSQL: the managed database's private address (GCP: an IP, AWS: a host name), the VM's IP (database.type = vm), or null (no VM runs it)"
  value = (local.managed
    ? one(concat(module.gcp[*].private_ip, module.aws[*].address))
    : local.postgres_vm == null ? null
    : cidrhost(var.config.clouds[coalesce(local.postgres_vm.cloud, local.cloud)].network.subnet_cidr, local.postgres_vm.ip_index)
  )
}
