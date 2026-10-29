variable "config" {
  description = "The private network and who may reach what"
  type = object({
    name              = string       # VPC name
    region            = string
    subnet_cidr       = string
    ssh_allowed_cidrs = list(string)
    internal_ports    = list(string)
    bastion_tag       = string
  })

  validation {
    condition     = length(var.config.ssh_allowed_cidrs) > 0 && !contains(var.config.ssh_allowed_cidrs, "0.0.0.0/0")
    error_message = "ssh_allowed_cidrs: list your own address(es), never 0.0.0.0/0."
  }
}
