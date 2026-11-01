variable "config" {
  description = "Configuration for secrets"
  type = object({
    secret_id              = string
    tunnel_token_secret_id = optional(string)
    account_id             = string
    display_name           = string
    roles                  = set(string)
  })
}