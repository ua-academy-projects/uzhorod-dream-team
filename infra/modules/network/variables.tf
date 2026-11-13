variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "nat_enabled" {
  type = bool
}

variable "subnets" {
  type = map(object({
    cidr                     = string
    private_ip_google_access = optional(bool, false)
  }))
}
