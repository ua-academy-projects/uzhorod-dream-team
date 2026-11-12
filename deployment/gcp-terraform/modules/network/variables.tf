variable "cfg" {
  type = object({
    google = object({
      project_id = string
      region     = string
    })
    network = object({
      name        = string
      subnet_cidr = string
      enable_nat  = optional(bool, true)
      public_tier = optional(string, "STANDARD")
      firewall_rules = map(object({
        source_tags   = optional(set(string), [])
        source_ranges = optional(set(string), [])
        target_tags   = set(string)
        ports         = set(number)
      }))
    })
    vm = object({
      ssh_port = optional(number, 222)
      instances = map(object({
        private_ip = string
        tags       = set(string)
        public_ip  = optional(bool, false)
      }))
    })
  })
}


variable "admin_ip" {
  type        = string
  description = "Public IP address or CIDR allowed to reach the bastion over SSH"
  sensitive   = true
  nullable    = false
}
