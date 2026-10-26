variable "project_id" {
  description = "GCP project to deploy into."
  type        = string
}

variable "region" {
  description = "Region of the subnets, the router and the NAT."
  type        = string
  default     = "europe-central2"
}

variable "zone" {
  description = "Zone of all VMs."
  type        = string
  default     = "europe-central2-a"
}

variable "backend" {
  description = "Where the queue and the sessions live."
  type        = string
  default     = "postgres"

  validation {
    condition     = contains(["redis", "postgres"], var.backend)
    error_message = "backend must be redis or postgres."
  }
}

variable "ssh_public_key_path" {
  description = "Public key of the jump user on the bastion and of the admin user behind it."
  type        = string
  default     = "~/.ssh/crypto-gcp.pub"
}

variable "admin_user" {
  description = "Admin account on the VMs behind the bastion."
  type        = string
  default     = "crypto"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_-]{0,31}$", var.admin_user))
    error_message = "admin_user must be a valid Linux user name."
  }
}

variable "console_user" {
  description = "User of the Console SSH button"
  type        = string
}

variable "image_tag" {
  description = "Image version to run, printed by ../build.sh (the git commit)."
  type        = string
  default     = null

  validation {
    condition     = var.image_tag == null || can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", var.image_tag))
    error_message = "image_tag must be a valid Docker tag."
  }
}

variable "domain" {
  description = "Name the app is served under over HTTPS."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain))
    error_message = "domain must be a lowercase DNS name."
  }
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone of the domain."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
    error_message = "cloudflare_zone_id is 32 hex characters."
  }
}

variable "ssh_source_ranges" {
  description = "Who may reach the bastion's public SSH port, x.x.x.x/32."
  type        = list(string)

  validation {
    condition     = alltrue([for cidr in var.ssh_source_ranges : can(cidrnetmask(cidr))])
    error_message = "ssh_source_ranges must be IPv4 CIDR blocks."
  }

  # 0.0.0.0/0 would open SSH to the whole internet.
  validation {
    condition     = alltrue([for cidr in var.ssh_source_ranges : !endswith(cidr, "/0")])
    error_message = "ssh_source_ranges must not contain /0: list your own IP as x.x.x.x/32."
  }
}

variable "cloudflare_token_secret" {
  description = "Secret Manager secret holding the Cloudflare API token."
  type        = string
  default     = "cloudflare-api-token"
}

variable "bastion_ssh_port" {
  description = "Public SSH port of the bastion."
  type        = number
  default     = 22022

  validation {
    condition     = var.bastion_ssh_port >= 1024 && var.bastion_ssh_port <= 65535
    error_message = "bastion_ssh_port must be between 1024 and 65535."
  }
}
