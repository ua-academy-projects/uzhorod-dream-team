variable "config" {
  description = "Configuration for secrets"
  type = object({
    secret_id    = string
    account_id   = string
    display_name = string
    roles        = set(string)
    services = map(object({
      secret_id    = string
      account_id   = string
      display_name = string
    }))
  })
}
