variable "config_path" {
  type        = string
  description = "Path to the unified JSON config"
  default     = "../config/deployment.json"
}

variable "bootstrap_config_path" {
  type        = string
  description = "Path to the bootstrap-generated JSON containing Google project and location settings"
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
