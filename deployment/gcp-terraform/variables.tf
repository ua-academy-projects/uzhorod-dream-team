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

variable "alert_channel_ids" {
  type        = list(string)
  description = "IDs of existing Cloud Monitoring notification channels that receive alerts, created by hand in the console. Pass them as TF_VAR_alert_channel_ids; the address itself never enters Terraform."
  default     = []
}
