variable "config" {
  description = "infra/config.json as a whole; this module uses prefix, location.region and network"
  type = object({
    prefix   = string
    location = object({ region = string })
    network = object({
      subnet_cidr    = string
      internal_ports = list(string)
    })
  })
}

variable "ssh_allowed_cidrs" {
  description = "Who may SSH to the bastion"
  type        = list(string)

  validation {
    condition     = length(var.ssh_allowed_cidrs) > 0 && !contains(var.ssh_allowed_cidrs, "0.0.0.0/0")
    error_message = "ssh_allowed_cidrs: list your own address(es), never 0.0.0.0/0."
  }
}
