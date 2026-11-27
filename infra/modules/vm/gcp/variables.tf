variable "config" {
  description = "infra/config.json as a whole; this module uses prefix and ssh.bastion_port"
  type = object({
    prefix = string
    ssh    = object({ bastion_port = number })
  })
}

variable "name" {
  description = "Which VM of config.json \"vms.instances\""
  type        = string
}

variable "vm" {
  description = "This VM in GCP's names (modules/vm): machine type, disk, image, project roles"
  type = object({
    ip_index  = number
    bastion   = bool
    tailscale = bool
    size      = string
    disk_type = string
    disk_gb   = number
    image     = string
    roles     = list(string)
  })
}

variable "region" {
  type = string
}

variable "zone" {
  type = string
}

variable "subnet_cidr" {
  description = "The VMs' subnet in GCP: the VM's IP is it + vm.ip_index"
  type        = string
}

variable "network_id" {
  description = "The VPC (the bastion routes the other clouds' subnets in it through itself)"
  type        = string
}

variable "subnet_id" {
  type = string
}

variable "firewall" {
  description = "The network tags the firewall rules match (modules/network)"
  type        = list(string)
}

variable "secret_ids" {
  description = "The secrets this VM reads: config.json name => id in Secret Manager (modules/secrets)"
  type        = map(string)
}

variable "peer_cidrs" {
  description = "The subnets of the other clouds in use: the bastion routes them through itself (Tailscale)"
  type        = list(string)
}
