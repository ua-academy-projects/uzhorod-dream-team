variable "admin_ip_cidr" {
  description = "Legacy administrator CIDR input; current IAP-only firewall does not use it."
  type        = string
  sensitive   = true
  default     = null

  validation {
    condition     = var.admin_ip_cidr == null ? true : can(cidrnetmask(var.admin_ip_cidr)) && endswith(var.admin_ip_cidr, "/32")
    error_message = "Specify the administrator public IPv4 address with a /32 prefix."
  }
}

variable "iap_members" {
  description = "Operators allowed to tunnel to bastion, e.g. user:admin@example.com. Existing SSH keys and Compute read permissions are still required."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for member in var.iap_members : can(regex("^(user|group|serviceAccount):[^ ]+@[^ ]+$", member))])
    error_message = "Use explicit user:, group: or serviceAccount: IAM identities."
  }
}

variable "image_publishers" {
  description = "Identities allowed to publish application images to this repository only."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for member in var.image_publishers : can(regex("^(user|group|serviceAccount):[^ ]+@[^ ]+$", member))])
    error_message = "Use explicit user:, group: or serviceAccount: IAM identities."
  }
}
