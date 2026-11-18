variable "config" {
  description = "infra/config.json as a whole; this module uses prefix, network.internal_ports, ssh.bastion_port and database.type"
  type = object({
    prefix   = string
    network  = object({ internal_ports = list(string) })
    ssh      = object({ bastion_port = number })
    database = object({ type = string })
  })
}

variable "region" {
  description = "The GCP region, e.g. europe-central2 (modules/network turns config.json's word into it)"
  type        = string
}

variable "subnet_cidr" {
  description = "The VMs' subnet in GCP (clouds.gcp.network.subnet_cidr)"
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "Who may SSH to the bastion"
  type        = list(string)
}
