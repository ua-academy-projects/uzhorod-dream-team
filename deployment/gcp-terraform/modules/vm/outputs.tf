output "instances" {
  value = {
    for name, vm in google_compute_instance.vms : name => {
      name         = vm.name
      instance_id  = vm.instance_id
      zone         = vm.zone
      private_ip   = vm.network_interface[0].network_ip
      public_ip    = try(vm.network_interface[0].access_config[0].nat_ip, null)
      data_disk_id = try(google_compute_disk.data[name].id, null)
    }
  }
}
