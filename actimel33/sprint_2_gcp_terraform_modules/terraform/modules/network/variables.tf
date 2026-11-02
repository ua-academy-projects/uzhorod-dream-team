variable "config" {
  description = "config.json; this module reads project.region and network"
  type = object({
    project = object({ region = string })
    network = object({
      vpc = string
      subnets = object({
        private    = object({ name = string, cidr = string })
        management = object({ name = string, cidr = string })
      })
      nat_router = string
    })
  })
}
