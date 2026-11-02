variable "config" {
  description = "config.json; this module reads dns and load_balancer.domain"
  type = object({
    dns           = object({ cloudflare_zone_id = string })
    load_balancer = object({ domain = string })
  })
}

variable "ip" {
  description = "Public IP of the load balancer the record points to"
  type        = string
}
