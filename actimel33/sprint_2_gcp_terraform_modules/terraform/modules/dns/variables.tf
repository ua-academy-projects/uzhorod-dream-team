variable "config" {
  description = "dns part of config.json"
  type = object({
    cloudflare_zone_id = string
  })
}

variable "domain" {
  description = "Full name of the record, from the load_balancer module"
  type        = string
}

variable "ip" {
  description = "Public IP of the load balancer the record points to"
  type        = string
}
