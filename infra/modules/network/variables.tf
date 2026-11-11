variable "config" {
  description = "infra/config.json as a whole; this module uses prefix, location.region, network and ssh.bastion_port"
  type = object({
    database = object({ type = string })
    prefix   = string
    location = object({ region = string })
    network = object({
      subnet_cidr    = string
      internal_ports = list(string)
    })
    ssh = object({ bastion_port = number })
  })

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