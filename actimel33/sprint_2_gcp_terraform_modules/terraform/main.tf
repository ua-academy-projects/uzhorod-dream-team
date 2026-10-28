# Entry point
locals {
  config = jsondecode(file("${path.module}/../../terraform_resources_configuration/config.json"))

  machines = local.config.machines
  services = local.config.google_project_services_list
  networks = local.config.networks

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

  secure_vpc               = local.networks.secure_vpc
  private_network          = local.networks.private_network
  management_subnet        = local.networks.management_subnet
  private_cidr             = local.networks.private_cidr
  management_cidr          = local.networks.management_cidr
  private_subnet_region    = local.networks.private_subnet_region
  management_subnet_region = local.networks.management_subnet_region
  nat_router_name          = local.networks.nat_router_name
  nat_router_region        = local.networks.nat_router_region

  depends_on = [module.project_services]
}

module "firewall" {
  source = "./modules/firewall"

  network_name = module.network.network_self_link
  # postgres or redis.
  rules = merge(local.config.firewalls, local.config.backend_firewalls[local.config.backend])
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

module "iam" {
  source = "./modules/iam"

  project_id     = local.config.project_id
  account_prefix = local.config.iam.service_account_prefix
  machine_roles  = { for name, machine in local.machines : name => try(machine.roles, []) }

  depends_on = [module.project_services]
}

module "secrets" {
  source = "./modules/secrets"

  secrets       = local.config.secrets
  reader_emails = module.iam.service_account_emails

  depends_on = [module.project_services]
}

module "artifact_registry" {
  source = "./modules/artifact_registry"

  repository_id = local.config.artifact_registry.repository_id
  location      = local.config.region
  format        = local.config.artifact_registry.format
  description   = local.config.artifact_registry.description
  labels        = local.labels
  reader_emails = { for name in local.config.artifact_registry.readers : name => module.iam.service_account_emails[name] }

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
  subnetwork   = each.value.in_management_subnet ? module.network.management_subnetwork_self_link : module.network.private_subnetwork_self_link
  network_tags = each.value.tags
  labels       = local.labels

  attached_disk_id          = try(module.data_disks[each.key].id, null)
  attached_disk_device_name = try(local.data_disks[each.key].device_name, null)

  service_account_email = module.iam.service_account_emails[each.key]
  has_public_ip         = false

  depends_on = [module.project_services]
}

module "load_balancer" {
  source = "./modules/load_balancer"

  name              = local.config.load_balancer.name
  zone              = local.machines[local.config.load_balancer.backend].zone
  instance_id       = module.compute_instances[local.config.load_balancer.backend].instance_id
  port              = local.config.load_balancer.port
  health_check_path = local.config.load_balancer.health_check_path
  domain_name       = local.config.load_balancer.domain

  depends_on = [module.project_services]
}

module "dns" {
  source = "./modules/dns"

  cloudflare_zone_id = local.config.dns.cloudflare_zone_id
  record_name        = local.config.load_balancer.domain
  lb_ip_address      = module.load_balancer.lb_public_ip_address
}

module "ssh_config" {
  source = "./modules/ssh_config"

  filename     = pathexpand("~/.ssh/config.d/gcp_crypto_modules.conf")
  project      = local.config.project_id
  zone         = local.machines[local.config.bastion_name].zone
  ssh_user     = local.config.ssh_user
  bastion_name = local.config.bastion_name
  hosts        = { for name, vm in module.compute_instances : name => vm.private_ip if name != local.config.bastion_name }
}
