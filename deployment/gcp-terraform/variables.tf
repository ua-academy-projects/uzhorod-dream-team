variable "config_path" {
  type        = string
  description = "Path to the unified JSON config"
  nullable    = false
}

variable "cloudflare_zone" {
  type        = string
  description = "Cloudflare Zone ID"
  sensitive   = true
  default     = null
}

variable "secret_payloads" {
  type        = map(string)
  description = "Map of secret variables to their values to set"
  sensitive   = true
  ephemeral   = true
  default     = {}
}

variable "secret_revisions" {
  type        = map(string)
  description = "Map of secret variables to their version numbers"
  default     = {}
}

variable "alert_email" {
  type        = string
  description = "Email address for monitoring alerts. Set by bootstrap.sh as TF_VAR_alert_email. Leave unset to create alerts without a notification channel."
  sensitive   = true
  default     = null
}

variable "admin_ip" {
  type        = string
  description = "Public IP address (or CIDR) allowed to reach the bastion over SSH. Set by bootstrap.sh as TF_VAR_admin_ip."
  sensitive   = true
  nullable    = false
}
