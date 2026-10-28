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
