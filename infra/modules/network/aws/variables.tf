variable "config" {
  description = "infra/config.json as a whole; this module uses prefix, network.internal_ports, ssh.bastion_port and database.type"
  type = object({
    prefix   = string
    network  = object({ internal_ports = list(string) })
    ssh      = object({ bastion_port = number })
    database = object({ type = string })
  })
}

variable "network" {
  description = "clouds.aws.network: the VPC and its subnets"
  type = object({
    vpc_cidr        = string
    subnet_cidr     = string
    public_subnet   = string
    database_subnet = string
  })
}

variable "zone" {
  description = "The AWS zone of the VMs, e.g. eu-north-1a (modules/network turns config.json's word into it)"
  type        = string
}

variable "database_zone" {
  description = "Another AWS zone, for the second database subnet"
  type        = string
}

variable "peer_cidrs" {
  description = "The subnets of the other clouds in use: their VMs reach ours through the bastions (Tailscale)"
  type        = list(string)
}

variable "ssh_allowed_cidrs" {
  description = "Who may SSH to the bastion"
  type        = list(string)
}

variable "account_id" {
  description = "The AWS account bootstrap.sh set up (TF_VAR_aws_account_id); empty = AWS not set up"
  type        = string
}
