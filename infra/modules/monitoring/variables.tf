variable "config" {
  type = object({
    project = object({
      id          = string
      name_prefix = string
    })
    app = object({
      POSTGRES_BACKEND = string
    })
    monitoring = object({
      ops_agent           = bool
      notification_emails = list(string)
      alerts = map(object({
        enabled    = bool
        threshold  = optional(number)
        duration_s = number
      }))
    })
  })
}
