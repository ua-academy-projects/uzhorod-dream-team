variable "cfg" {
  type = object({
    google = object({
      project_id = string
      region     = string
    })
    vm_options = optional(object({
      ssh_port = optional(number, 222)
    }), {})
    network = object({
      name         = string
      subnet_cidr  = string
      admin_ranges = optional(set(string), [])
      enable_nat   = optional(bool, true)
      public_tier  = optional(string, "STANDARD")
      firewall_rules = map(object({
        source_tags   = optional(set(string), [])
        source_ranges = optional(set(string), [])
        target_tags   = set(string)
        ports         = set(number)
      }))
    })
    vm = map(object({
      private_ip = string
      tags       = set(string)
      public_ip  = optional(bool, false)
    }))
  })
}

