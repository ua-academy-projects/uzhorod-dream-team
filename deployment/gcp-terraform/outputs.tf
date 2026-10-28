output "vms" {
  value = {
    for role, vm in module.vm : role => {
      name         = vm.name
      zone         = vm.zone
      private_ip   = vm.private_ip
      public_ip    = vm.public_ip
      data_disk_id = vm.data_disk_id
    }
  }
}
