variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID of the domain"
  type        = string
}

variable "record_name" {
  description = "Full name of the record, e.g. crypto.example.com"
  type        = string
}

variable "lb_ip_address" {
  description = "Public IP of the load balancer the record points to"
  type        = string
}
