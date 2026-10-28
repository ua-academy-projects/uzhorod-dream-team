variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "config" {
  type = object({
    name                = string
    subnet_cidr         = string
    enable_nat          = optional(bool, true)
    public_network_tier = optional(string, "STANDARD")
    firewall_rules = map(object({
      source_tags   = optional(set(string), [])
      source_ranges = optional(set(string), [])
      target_tags   = set(string)
      ports         = set(number)
    }))
  })
}

variable "vms" {
  type = map(object({
    private_ip = string
    tags       = set(string)
    public_ip  = optional(bool, false)
  }))
}

