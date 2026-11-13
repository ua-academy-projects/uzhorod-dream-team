variable "zone_id" {
  type = string
}

variable "frontend_subdomain" {
  type = string
}

variable "ttl" {
  type = number
}

variable "frontend_ip" {
  type = string
}

variable "proxied" {
  type = bool
}
