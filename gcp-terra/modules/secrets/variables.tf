variable "config" {
  description = "Shared configuration; this module selects its own settings."
  type = object({
    secret_manager = object({
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
  })
}
