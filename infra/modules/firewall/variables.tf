variable "network" {
  type = string
}

# the address of whoever runs terraform; "MY_IP" in ssh.bastion_from stands for it
variable "my_ip" {
  type = string
}

# Cloudflare's IPv4 ranges; "CLOUDFLARE" in public_from stands for them (a proxied DNS record reaches the origin from these addresses)
variable "cloudflare_ranges" {
  type = list(string)
}

variable "ssh" {
  type = object({
    bastion_from = list(string)
    iap          = bool
  })
}

# service catalog: who may reach which ports (allow_from = instance names, public_from = CIDR ranges, or the words MY_IP and CLOUDFLARE)
variable "services" {
  type = map(object({
    ports       = optional(list(number), [])
    allow_from  = optional(list(string), [])
    public_from = optional(list(string), [])
  }))
}

# an instance runs the services it lists, by default the one named after itself; its network tag is its name
variable "instances" {
  type = map(object({
    services = optional(list(string))
    bastion  = optional(bool, false)
  }))
}
