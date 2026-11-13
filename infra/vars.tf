variable "config_path" {
  type    = string
  default = "config.json"
}

# IAM member allowed to impersonate the ansible service account, e.g. user:you@example.com (set by terraform.env)
variable "operator_member" {
  type = string
}

variable "history_pass" {
  type      = string
  sensitive = true
}

variable "cloudflare_token" {
  type      = string
  sensitive = true
}
