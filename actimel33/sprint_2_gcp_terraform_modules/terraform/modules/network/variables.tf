variable "config" {
  description = "network part of config.json"
  type = object({
    vpc = string
    subnets = object({
      private    = object({ name = string, cidr = string })
      management = object({ name = string, cidr = string })
    })
    nat_router = string
  })
}

variable "region" {
  description = "Region of the subnets and the NAT router"
  type        = string
}
