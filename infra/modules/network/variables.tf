variable "config" {
  description = "infra/config.json as a whole; this module uses prefix, default_cloud, region, zone, clouds.<cloud> (location, network), network.internal_ports, ssh.bastion_port, vms.instances (cloud) and database.type"
  type = object({
    prefix        = string
    default_cloud = string
    region        = string
    zone          = string
    clouds        = any 
    network       = object({ internal_ports = list(string) })
    ssh           = object({ bastion_port = number })
    vms = object({
      instances = map(object({ cloud = optional(string) }))
    })
    k3s = optional(object({
      cloud = optional(string)
      nodes = map(object({}))
    }))
    database = object({ type = string })
  })

  validation {
    condition = alltrue([
      for cloud in distinct(concat([var.config.default_cloud], [for vm in values(var.config.vms.instances) : vm.cloud if vm.cloud != null])) :
      can(var.config.clouds[cloud].location.regions[var.config.region]) && can(var.config.clouds[cloud].location.zones[var.config.zone])
    ])
    error_message = "config.json: region \"${var.config.region}\" or zone \"${var.config.zone}\" is not in clouds.<cloud>.location of a cloud in use."
  }

  validation {
    condition     = var.config.ssh.bastion_port != 22
    error_message = "config.json: ssh.bastion_port must not be 22 (the bastion's SSH is moved off the default port)."
  }
}

variable "ssh_allowed_cidrs" {
  description = "Who may SSH to the bastion"
  type        = list(string)

  validation {
    condition     = length(var.ssh_allowed_cidrs) > 0 && !contains(var.ssh_allowed_cidrs, "0.0.0.0/0")
    error_message = "ssh_allowed_cidrs: list your own address(es), never 0.0.0.0/0."
  }
}

variable "aws_account_id" {
  description = "The AWS account bootstrap.sh set up (TF_VAR_aws_account_id); empty = AWS not set up"
  type        = string
}