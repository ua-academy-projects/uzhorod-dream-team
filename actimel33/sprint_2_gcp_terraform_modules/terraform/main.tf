# Entry point
locals {
  config = jsondecode(file("${path.module}/../../terraform_resources_configuration/config.json"))

  machines         = local.config.machines
  services         = local.config.google_project_services_list
  lb_source_ranges = local.config.lb_source_ranges_list
  networks         = local.config.networks

  # Machines that keep their data on a separate disk (data_disk in config.json).
  data_disks = { for name, machine in local.machines : name => machine.data_disk if can(machine.data_disk) }

  labels = {
    env        = local.config.env
    managed_by = "terraform"
  }
}

module "project_services" {
  source = "./modules/project_services"

  services = local.services
}

module "network" {
  source = "./modules/network"

  secure_vpc            = local.networks.secure_vpc
  private_network       = local.networks.private_network
  edge_network          = local.networks.edge_network
  private_cidr          = local.networks.private_cidr
  edge_cidr             = local.networks.edge_cidr
  private_subnet_region = local.networks.private_subnet_region
  edge_subnet_region    = local.networks.edge_subnet_region
  nat_router_name       = local.networks.nat_router_name
  nat_router_region     = local.networks.nat_router_region

  depends_on = [module.project_services]
}

module "firewall" {
  source = "./modules/firewall"

  network_name     = module.network.network_self_link
  iap_cidr         = local.networks.iap_cidr
  edge_cidr        = local.networks.edge_cidr
  lb_source_ranges = local.lb_source_ranges
}

module "data_disks" {
  source   = "./modules/data_disk"
  for_each = local.data_disks

  name   = each.value.name
  zone   = local.machines[each.key].zone
  size   = each.value.size
  type   = each.value.type
  labels = local.labels

  depends_on = [module.project_services]
}

module "compute_instances" {
  source   = "./modules/compute_instance"
  for_each = local.machines

  name         = each.key
  machine_type = each.value.type
  zone         = each.value.zone
  image        = each.value.image
  disc_size    = each.value.disc_size
  disc_type    = each.value.disc_type
  subnetwork   = each.value.has_edge ? module.network.edge_subnetwork_self_link : module.network.private_subnetwork_self_link
  network_tags = each.key == "bastion" ? ["bastion-vm"] : (each.key == "ui" ? ["internal-vm", "ui-vm"] : ["internal-vm"])
  labels       = local.labels

  attached_disk_id          = try(module.data_disks[each.key].id, null)
  attached_disk_device_name = try(local.data_disks[each.key].device_name, null)

  # No public IPs: the bastion is reached through IAP, the rest through the bastion.
  has_public_ip = false

  depends_on = [module.project_services]
}

module "ssh_config" {
  source = "./modules/ssh_config"

  filename     = pathexpand("~/.ssh/config.d/gcp_crypto_modules.conf")
  project      = local.config.project_id
  zone         = local.machines.bastion.zone
  ssh_user     = local.config.ssh_user
  bastion_name = "bastion"
  hosts        = { for name, vm in module.compute_instances : name => vm.private_ip if name != "bastion" }
}
