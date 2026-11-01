variable "admin_ip_cidr" {
  description = "Allowed public IPv4 CIDR for Bastion SSH"
  type        = string
  sensitive   = true

  validation {
    condition     = can(cidrnetmask(var.admin_ip_cidr)) && endswith(var.admin_ip_cidr, "/32")
    error_message = "Specify the administrator public IPv4 address with a /32 prefix."
  }
}
