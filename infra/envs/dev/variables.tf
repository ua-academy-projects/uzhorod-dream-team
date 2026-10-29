variable "project_id" {
  description = "The GCP project (made by infra/bootstrap)"
  type        = string
}

variable "region" {
  type = string
}

variable "zone" {
  type = string
}

variable "my_ip" {
  description = "Your public IPv4: only it may SSH to the bastion"
  type        = string

  validation {
    condition     = can(cidrhost("${var.my_ip}/32", 0))
    error_message = "my_ip must be one IPv4 address, e.g. 203.0.113.7 (without /32)."
  }
}
