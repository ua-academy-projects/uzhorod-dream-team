output "vms" {
  value = {
    for role, vm in module.vm.instances : role => {
      name         = vm.name
      zone         = vm.zone
      private_ip   = vm.private_ip
      public_ip    = vm.public_ip
      data_disk_id = vm.data_disk_id
    }
  }
}

output "cloud_sql" {
  value = {
    connection_name = module.cloud_sql.connection_name
    dns_name        = module.cloud_sql.dns_name
    endpoint_ip     = module.cloud_sql.endpoint_ip
  }
}
