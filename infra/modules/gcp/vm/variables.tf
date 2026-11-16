variable "config" {
  description = "infra/config.json as a whole; this module uses prefix, clouds.gcp (region, zones, sizes, os), network.subnet_cidr and ssh"
  type = object({
    prefix = string
    clouds = object({
      gcp = object({
        region = string
        zones  = list(string)
        sizes  = map(string)
        os     = map(string)
      })
    })
    network = object({ subnet_cidr = string })
    ssh = object({
      user         = string
      bastion_port = number
    })
  })
}

variable "name" {
  description = "Which VM of config.json \"vms.instances\""
  type        = string
}

variable "vm" {
  description = "This VM as modules/layout worked it out: vms.defaults filled in, the switches applied"
  type = object({
    host     = number
    bastion  = bool
    size     = string
    os       = string
    disk_gb  = number
    services = list(string)
  })
}

variable "subnetwork_id" {
  type = string
}

variable "bastion_tag" {
  description = "The network tag the firewall opens SSH for (modules/gcp/network)"
  type        = string
}

variable "service_account" {
  description = "E-mail of the account the VM runs as (modules/gcp/iam)"
  type        = string
}
