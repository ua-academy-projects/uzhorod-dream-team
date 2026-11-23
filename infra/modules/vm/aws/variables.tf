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
  description = "This VM in AWS's names (modules/vm): instance type, disk, AMI (owner + name pattern), managed policies"
  type = object({
    host      = number
    bastion   = bool
    tailscale = bool
    size      = string
    disk_type = string
    disk_gb   = number
    image     = object({ owner = string, name = string })
    roles     = list(string)
  })
}

variable "region" {
  description = "The AWS region, e.g. eu-north-1 (the bastion's cloud-init reads its secrets there)"
  type        = string
}

variable "network" {
  description = "clouds.aws.network: the subnets' ranges"
  type = object({
    subnet_cidr   = string
    public_subnet = string
  })
}

variable "subnets" {
  description = "Where the VM goes (modules/network): private = the VMs, public = the bastion"
  type = object({
    private = string
    public  = string
  })
}

variable "private_route_table_id" {
  description = "The private subnets' route table: the bastion adds 0.0.0.0/0 -> itself there (NAT)"
  type        = string
}

variable "firewall" {
  description = "The security groups of this VM (modules/network)"
  type        = list(string)
}

variable "secret_ids" {
  description = "The secrets this VM reads: config.json name => ARN in Secrets Manager (modules/secrets)"
  type        = map(string)
}

variable "peer_cidrs" {
  description = "The subnets of the other clouds in use: the bastion routes them through itself (Tailscale)"
  type        = list(string)
}
