variable "config_file" {
  description = "Nonsecret configuration JSON, relative to this root module or absolute."
  type        = string
  default     = "../config.json"
  nullable    = false
  validation {
    condition     = can(jsondecode(file(startswith(var.config_file, "/") ? var.config_file : "${path.root}/${var.config_file}")))
    error_message = "config_file must point to an existing valid JSON file."
  }
}

variable "monitoring_file" {
  description = "Nonsecret monitoring JSON, relative to this root module or absolute."
  type        = string
  default     = "../monitoring.json"
  nullable    = false
  validation {
    condition     = can(jsondecode(file(startswith(var.monitoring_file, "/") ? var.monitoring_file : "${path.root}/${var.monitoring_file}")).monitoring)
    error_message = "monitoring_file must point to valid JSON with a monitoring object."
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
